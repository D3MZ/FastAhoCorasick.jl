# Dependency-free horizontal bar chart of bench/results.csv (min match time per impl).
rows = readlines(joinpath(@__DIR__, "results.csv"))[2:end]
labels = String[]; ms = Float64[]; allocs = Int[]
for r in rows
    f = split(r, ',')
    push!(labels, f[1]); push!(ms, parse(Float64, f[2]) / 1e6); push!(allocs, parse(Int, f[4]))
end
isrust = [startswith(l, "Rust") for l in labels]

W, H = 940, 360
padL, padR, padT, padB = 210, 90, 54, 30
n = length(labels)
bh = (H - padT - padB) / n * 0.62
gap = (H - padT - padB) / n
xmax = maximum(ms) * 1.14
xscale(v) = padL + v / xmax * (W - padL - padR)

io = IOBuffer()
println(io, """<svg xmlns="http://www.w3.org/2000/svg" width="$W" height="$H" font-family="Helvetica,Arial,sans-serif">""")
println(io, """<rect width="$W" height="$H" fill="white"/>""")
println(io, """<text x="$(W÷2)" y="26" text-anchor="middle" font-size="17" font-weight="bold">FastAhoCorasick.jl vs Rust aho-corasick — match time, 6 MB corpus, Apple M1 Max (single thread)</text>""")
println(io, """<text x="$(W÷2)" y="44" text-anchor="middle" font-size="12" fill="#666">lower is better · all Julia kernels are 0-allocation · counts identical</text>""")
for i in 1:n
    y = padT + (i - 1) * gap + (gap - bh) / 2
    col = isrust[i] ? "#d1495b" : (labels[i] == "Julia serial (1 stream)" ? "#8a8a8a" : "#1f7a4d")
    bw = xscale(ms[i]) - padL
    println(io, """<text x="$(padL-10)" y="$(y+bh/2+4)" text-anchor="end" font-size="12">$(labels[i])</text>""")
    println(io, """<rect x="$padL" y="$y" width="$bw" height="$bh" fill="$col" rx="2"/>""")
    tag = allocs[i] == 0 ? "0 alloc" : "$(allocs[i]) alloc"
    println(io, """<text x="$(xscale(ms[i])+6)" y="$(y+bh/2+4)" font-size="12" fill="#333">$(round(ms[i],digits=2)) ms · $tag</text>""")
end
# x axis ticks
for t in 0:3
    v = xmax * t / 3; xx = xscale(v)
    println(io, """<line x1="$xx" y1="$padT" x2="$xx" y2="$(H-padB)" stroke="#eee"/>""")
    println(io, """<text x="$xx" y="$(H-padB+16)" text-anchor="middle" font-size="10" fill="#888">$(round(v,digits=1)) ms</text>""")
end
println(io, "</svg>")
write(joinpath(@__DIR__, "benchmark.svg"), String(take!(io)))
println("wrote bench/benchmark.svg")
