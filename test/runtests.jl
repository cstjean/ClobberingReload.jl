using ClobberingReload
using Base.Test

cp("F1.jl", "F.jl", remove_destination=true)

push!(LOAD_PATH, dirname(Base.source_path()))

@ausing AA
@ausing DD
@ausing BB <: (AA, DD)

@test something == "happy"
@test likes == "happy banana cards"

cp("F2.jl", "F.jl", remove_destination=true)

# ... This is kinda silly, but: we're making sure the time-stamps are different.
# I've had intermittent failures without these three lines. Not sure what the
# proper way of doing it, but it doesn't matter much anyway, it's just a test.
touch("F.jl")
sleep(0.5) 
touch("F.jl")

areload()

@test something == "green"
@test likes == "green banana cards"

################################################################################

if VERSION >= v"0.6.0"
    using ParametricTypeAlias
    creload_strip("ParametricTypeAlias")
    @test isa(Int[1,2,3], ParametricTypeAlias.MyVector{Int})
end

################################################################################

a = ClobberingReload.parse_file("docstring.jl")[1]
@test ClobberingReload.strip_docstring(a).head == :function

################################################################################
# RevertibleCodeUpdate

counter = fill(0)
function add_counter(fdef)
    di = ClobberingReload.splitdef(fdef)
    di[:body] = quote $counter .+= 1; $(di[:body]) end
    ClobberingReload.combinedef(di)
end
upd_high = update_code_revertible(AA.high) do code
    add_counter(code)
end
upd_module = update_code_revertible(AA) do code
    if ClobberingReload.is_function_definition(code) add_counter(code) end
end
@test AA.high(1) == 10
@test counter[] == 0
upd_high() do
    @test AA.high(1) == 10
    @test AA.high(1.0) == 2
end
@test AA.high(1) == 10
@test AA.bar(1.0) == 2
@test counter[] == 2 # only the two calls within `upd` increase the counter
upd_module() do
    @test AA.high(1) == 10
    @test AA.high(1.0) == 2
end
@test counter[] == 5 # three calls, since `bar` also becomes counting
