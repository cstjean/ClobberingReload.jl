""" Docstring """
module AA

export x, y

include("CC.jl")

immutable Part
    u
end
    
foo(x) = x+100

const x = 1009
y = 2005001

end
