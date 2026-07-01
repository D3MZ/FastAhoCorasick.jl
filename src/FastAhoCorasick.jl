"""
    FastAhoCorasick

A native-Julia Aho-Corasick multi-pattern string matcher with **zero heap allocations**
in the match hot loop and a single-thread **multi-stream ILP** kernel that outperforms
Rust's `aho-corasick` crate on this latency-bound workload.

Matching operates on raw UTF-8 **bytes** and folds **ASCII** case only, mirroring
`aho_corasick`'s `.ascii_case_insensitive(true)` — so non-ASCII (Cyrillic/CJK/Arabic)
keywords match identically byte-for-byte.

The count semantics match `AhoCorasick::find_iter().count()` in the crate's default
`MatchKind::Standard`: leftmost, non-overlapping matches.

# Example
```julia
a = build(["trading", "strategy", "финансы", "市场"])
count_matches(a, "trading strategy on the 市场")          # => 3
```
"""
module FastAhoCorasick

export Automaton, build, count_matches, count_matches_serial, sum_weights

using Base.Cartesian: @nexprs

# ASCII case-insensitive fold: A-Z -> a-z
@inline fold(b::UInt8) = (b - 0x41 < 0x1a) ? (b + 0x20) : b

"""
    Automaton

A compiled Aho-Corasick automaton laid out as a byte-class, premultiplied DFA:

  * `classof[byte+1]` maps each byte to an equivalence class `0..k`. Every byte absent
    from the pattern alphabet shares class `0` (their transition columns are identical),
    shrinking the table so it stays L1-resident.
  * State ids are **premultiplied**: a state's row begins at index `state`, and stored
    successors are themselves premultiplied — so the hot loop is `next[state + class + 1]`
    with no multiply on the dependent-load critical path.
  * States are ordered so every match state has id `< thresh`; a match is the compare
    `state < thresh`, avoiding a second dependent load per byte.
"""
struct Automaton
    classof::Vector{UInt8}
    next::Vector{UInt32}      # premultiplied transition table
    weightp::Vector{Float64}  # weight indexed by (premultiplied state) + 1
    width::Int                # number of byte classes
    thresh::UInt32            # state < thresh  <=>  match state
    root::UInt32              # premultiplied root id
    nstates::Int
end

"""
    build(patterns; weights=nothing) -> Automaton

Compile `patterns` (a vector of strings) into an [`Automaton`]. Matching is
ASCII-case-insensitive. If `weights` is given (one `Float64` per pattern), the automaton
can be used with [`sum_weights`](@ref).
"""
function build(patterns::Vector{<:AbstractString}; weights::Union{Nothing,Vector{Float64}}=nothing)
    isempty(patterns) && throw(ArgumentError("patterns must be non-empty"))
    weights === nothing || length(weights) == length(patterns) ||
        throw(ArgumentError("weights must have one entry per pattern"))

    # --- alphabet reduction: one class per distinct folded pattern byte ---
    classof = zeros(UInt8, 256)
    k = 0
    for pat in patterns, ch in codeunits(pat)
        b = fold(ch)
        if classof[Int(b)+1] == 0
            k += 1
            classof[Int(b)+1] = UInt8(k)
        end
    end
    for b in 0x61:0x7a                      # mirror uppercase onto lowercase class
        c = classof[Int(b)+1]
        c != 0 && (classof[Int(b)-0x20+1] = c)
    end
    W = k + 1

    @inline classix(b::UInt8) = Int(classof[Int(b)+1])

    # --- trie (goto) keyed by class ---
    goto = [Dict{Int,Int}()]                # state 1 = root
    outpat = [0]
    addstate!() = (push!(goto, Dict{Int,Int}()); push!(outpat, 0); length(goto))
    for (pid, pat) in enumerate(patterns)
        s = 1
        for ch in codeunits(pat)
            c = classix(fold(ch))
            nxt = get(goto[s], c, 0)
            if nxt == 0
                nxt = addstate!()
                goto[s][c] = nxt
            end
            s = nxt
        end
        outpat[s] == 0 && (outpat[s] = pid)  # first (highest priority) pattern wins
    end

    n = length(goto)
    fail = fill(1, n)
    trans = Vector{Int}(undef, n * W)       # transitions over classes, original ids
    out = zeros(Int, n)

    # BFS: compute fail links and bake DFA transitions
    queue = Int[]
    for c in 0:k
        s = get(goto[1], c, 0)
        if s == 0
            trans[c + 1] = 1
        else
            trans[c + 1] = s
            fail[s] = 1
            push!(queue, s)
        end
    end
    head = 1
    while head <= length(queue)
        s = queue[head]; head += 1
        fbase = (fail[s]-1)*W
        sbase = (s-1)*W
        for c in 0:k
            t = get(goto[s], c, 0)
            if t == 0
                trans[sbase + c + 1] = trans[fbase + c + 1]
            else
                fail[t] = trans[fbase + c + 1]
                trans[sbase + c + 1] = t
                push!(queue, t)
            end
        end
    end

    out[1] = outpat[1]
    for s in queue
        out[s] = outpat[s] == 0 ? out[fail[s]] : outpat[s]
    end

    # --- reorder so all match states get the smallest ids ---
    remap = Vector{Int}(undef, n)
    m = 0
    for s in 1:n
        out[s] != 0 && (m += 1; remap[s] = m)
    end
    nxtid = m
    for s in 1:n
        out[s] == 0 && (nxtid += 1; remap[s] = nxtid)
    end

    next = Vector{UInt32}(undef, n * W)
    weightp = zeros(Float64, n * W)
    for s in 1:n
        prem = (remap[s] - 1) * W
        for c in 0:k
            next[prem + c + 1] = UInt32((remap[trans[(s-1)*W + c + 1]] - 1) * W)
        end
        if out[s] != 0 && weights !== nothing
            weightp[prem + 1] = weights[out[s]]
        end
    end

    Automaton(classof, next, weightp, W, UInt32(m * W), UInt32((remap[1] - 1) * W), n)
end

# ---------------------------------------------------------------------------
# Serial kernel: one dependent load per byte.
# ---------------------------------------------------------------------------

"""
    count_matches_serial(a::Automaton, ptr::Ptr{UInt8}, n::Integer) -> Int
    count_matches_serial(a::Automaton, data) -> Int

Count leftmost non-overlapping matches with a single DFA stream. Zero allocations.
This is the direct analogue of Rust's `find_iter().count()`.
"""
function count_matches_serial(a::Automaton, ptr::Ptr{UInt8}, n::Integer)
    classof = a.classof; next = a.next; thresh = a.thresh; root = a.root
    state = root; cnt = 0
    @inbounds for i in 1:n
        b = unsafe_load(ptr, i)
        state = next[Int(state) + Int(classof[Int(b)+1]) + 1]
        if state < thresh
            cnt += 1; state = root
        end
    end
    cnt
end

# ---------------------------------------------------------------------------
# Multi-stream ILP kernel (single thread): interleave N independent DFA chains so the
# out-of-order engine overlaps their (otherwise serial) load latencies. Exactness under
# non-overlapping semantics is preserved by a seam fixup that replays each internal
# boundary from the TRUE entering state, threaded forward via `carry` so it stays exact
# even for periodic/self-overlapping patterns.
# ---------------------------------------------------------------------------

@generated function _count_ilp(a::Automaton, ptr::Ptr{UInt8}, n::Integer, ::Val{N}) where {N}
    quote
        classof = a.classof; next = a.next; thresh = a.thresh; root = a.root
        n = Int(n)
        n < 64 * N && return count_matches_serial(a, ptr, n)
        seg = n ÷ N
        cnt = 0
        @nexprs $N k -> (s_k = root)
        @inbounds for t in 1:seg
            @nexprs $N k -> begin
                b_k = unsafe_load(ptr, (k - 1) * seg + t)
                s_k = next[Int(s_k) + Int(classof[Int(b_k) + 1]) + 1]
                if s_k < thresh
                    cnt += 1
                    s_k = root
                end
            end
        end
        @inbounds for i in ($N * seg + 1):n     # tail continues on the last stream
            b = unsafe_load(ptr, i)
            $(Symbol("s_", N)) = next[Int($(Symbol("s_", N))) + Int(classof[Int(b) + 1]) + 1]
            if $(Symbol("s_", N)) < thresh
                cnt += 1
                $(Symbol("s_", N)) = root
            end
        end
        carry = s_1                             # true state entering segment 2
        @nexprs $(N - 1) k -> begin
            @inbounds begin
                strue = carry; sfake = root; j = k * seg + 1
                limit = k == $(N - 1) ? n : (k + 1) * seg     # last seam absorbs the tail
                while j <= limit && strue != sfake
                    b = unsafe_load(ptr, j)
                    c = Int(classof[Int(b) + 1])
                    strue = next[Int(strue) + c + 1]
                    if strue < thresh
                        cnt += 1
                        strue = root
                    end
                    sfake = next[Int(sfake) + c + 1]
                    if sfake < thresh
                        cnt -= 1
                        sfake = root
                    end
                    j += 1
                end
                carry = (strue == sfake) ? s_{k + 1} : strue
            end
        end
        cnt
    end
end

"""
    count_matches(a::Automaton, data; streams::Integer=8) -> Int

Count leftmost non-overlapping matches of `data` (an `AbstractString`, `Ptr{UInt8}`
with a length, or byte vector). Uses a single-thread multi-stream ILP kernel with
`streams` interleaved DFA chains (default 8), falling back to the serial kernel for
short inputs. Zero allocations. Result is identical to [`count_matches_serial`](@ref).

For a call-site-constant, allocation-free `streams`, pass a `Val`:
`count_matches(a, ptr, n, Val(8))`.
"""
count_matches(a::Automaton, ptr::Ptr{UInt8}, n::Integer, ::Val{N}) where {N} = _count_ilp(a, ptr, n, Val(N))

@inline function count_matches(a::Automaton, ptr::Ptr{UInt8}, n::Integer; streams::Integer=8)
    s = Int(streams)
    s <= 1 && return count_matches_serial(a, ptr, n)
    s == 2 && return _count_ilp(a, ptr, n, Val(2))
    s == 3 && return _count_ilp(a, ptr, n, Val(3))
    s == 4 && return _count_ilp(a, ptr, n, Val(4))
    s == 6 && return _count_ilp(a, ptr, n, Val(6))
    s == 8 && return _count_ilp(a, ptr, n, Val(8))
    s == 12 && return _count_ilp(a, ptr, n, Val(12))
    s == 16 && return _count_ilp(a, ptr, n, Val(16))
    _count_ilp(a, ptr, n, Val(8))   # nearest supported
end

# --- convenience methods over strings / byte vectors ---
for f in (:count_matches, :count_matches_serial)
    @eval function $f(a::Automaton, data::AbstractString; kw...)
        GC.@preserve data $f(a, pointer(data), ncodeunits(data); kw...)
    end
    @eval function $f(a::Automaton, data::AbstractVector{UInt8}; kw...)
        GC.@preserve data $f(a, pointer(data), length(data); kw...)
    end
end

"""
    sum_weights(a::Automaton, data) -> Float64

Sum the weights (supplied to [`build`](@ref)) of every leftmost non-overlapping match.
Zero allocations. Single stream.
"""
function sum_weights(a::Automaton, ptr::Ptr{UInt8}, n::Integer)
    classof = a.classof; next = a.next; weightp = a.weightp; thresh = a.thresh; root = a.root
    state = root; acc = 0.0
    @inbounds for i in 1:n
        b = unsafe_load(ptr, i)
        state = next[Int(state) + Int(classof[Int(b)+1]) + 1]
        if state < thresh
            acc += weightp[Int(state) + 1]; state = root
        end
    end
    acc
end
sum_weights(a::Automaton, data::AbstractString) = GC.@preserve data sum_weights(a, pointer(data), ncodeunits(data))
sum_weights(a::Automaton, data::AbstractVector{UInt8}) = GC.@preserve data sum_weights(a, pointer(data), length(data))

end # module
