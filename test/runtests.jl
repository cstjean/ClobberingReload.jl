using ClobberingReload
using Base.Test

cp("F1.jl", "F.jl", remove_destination=true)

push!(LOAD_PATH, dirname(Base.source_path()))

@ausing AA
@ausing BB <: AA

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

