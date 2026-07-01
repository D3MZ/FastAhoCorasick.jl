# Deterministic, dependency-free corpus generator (no network, reproducible across machines).
# Interleaves multilingual sentence fragments via a fixed LCG until the target size is hit,
# so both the Julia and Rust benchmarks run on byte-identical input.
const TARGET = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 6_000_000
const OUT = length(ARGS) >= 2 ? ARGS[2] : joinpath(@__DIR__, "corpus.txt")

const FRAGMENTS = [
    "the relative strength index is a momentum oscillator used in trading ",
    "estrategia de trading en el mercado financiero con analisis tecnico ",
    "strategie de trading sur le marche financier et gestion du risque ",
    "handelsstrategie fuer den finanzmarkt mit indikatoren und signalen ",
    "торговая стратегия на финансовом рынке и управление капиталом ",
    "交易策略 金融市场 技术分析 风险管理 投资组合 收益 ",
    "取引戦略 金融市場 テクニカル分析 リスク管理 ",
    "استراتيجية التداول في السوق المالية وإدارة المخاطر ",
    "a quick brown fox jumps over the lazy dog near the river bank ",
    "quarterly earnings guidance revenue margin cash flow balance sheet ",
    "lorem ipsum dolor sit amet consectetur adipiscing elit sed do ",
    "the market and the strategy for finance drive investment returns ",
]

function main()
    io = IOBuffer(sizehint = TARGET + 512)
    state = UInt64(0x9E3779B97F4A7C15)          # fixed seed
    while io.size < TARGET
        state = state * 6364136223846793005 + 1442695040888963407
        idx = Int(state >> 33) % length(FRAGMENTS) + 1
        write(io, FRAGMENTS[idx])
    end
    open(OUT, "w") do f
        write(f, take!(io))
    end
    println("wrote $OUT ($(filesize(OUT)) bytes)")
end
main()
