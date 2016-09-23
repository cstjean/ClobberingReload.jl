# ClobberingReload

[![Build Status](https://travis-ci.org/cstjean/ClobberingReload.jl.svg?branch=master)](https://travis-ci.org/cstjean/ClobberingReload.jl)

[![Coverage Status](https://coveralls.io/repos/cstjean/ClobberingReload.jl/badge.svg?branch=master&service=github)](https://coveralls.io/github/cstjean/ClobberingReload.jl?branch=master)

[![codecov.io](http://codecov.io/github/cstjean/ClobberingReload.jl/coverage.svg?branch=master)](http://codecov.io/github/cstjean/ClobberingReload.jl?branch=master)

`ClobberingReload.creload(modulename)` is a drop-in replacement for
`reload(modulename)`, that does not require rebuilding the state after `reload`,
because the reloaded module's new functions are applicable to the existing
objects. It is ideally suited for exploratory REPL-heavy workflows, and also
works with modules imported via `using` (so no need for prefixing every function
call with its module name)

Additionally, `ClobberingReload` provides functionality for automatically
reloading modified modules. It is a direct successor to **@malmaud**'s
[Autoreload.jl](https://github.com/malmaud/Autoreload.jl) (and a straight
replacement). Its main trick is taken from
[atom-julia-client](https://github.com/JunoLab/atom-julia-client).

## Installation

ClobberingReload is not yet registered in METADATA. Install with

```julia
Pkg.clone("git://github.com/cstjean/ClobberingReload.jl.git")
```

and please report any issues you encounter.

## Usage

```julia
using ClobberingReload
using Houses

h = House(nwindows=10)
println("Price of house:$(price(h))")
> Price of house: 100

.... modify Houses.jl, change the `price` function ....

println("Price of house:$(price(h))")
> Price of house: 130
```

## Autoreload

In [IJulia](https://github.com/JuliaLang/IJulia.jl) (Jupyter notebooks), `creload` will be called
automatically for modules that were imported using `@ausing` or `@aimport`,
whenever the module's source code has been changed. For example:

```julia
using ClobberingReload

using Images    # regular using
@ausing Foo     # autoreloaded using
@aimport Bar    # autoreloaded import

println(Bar.life_the_universe())
> 5

# ... modify Bar.jl, or one of its `include`d files

println(Bar.life_the_universe())
>   INFO: Reloading `Bar`
> 42
```

The Julia REPL [does not support automatic calling of code yet](https://github.com/JuliaLang/julia/issues/6445), but you can still trigger the autoreload feature for `@aimport`ed modules by calling `areload()` manually.

## How `creload` works

Julia's `reload(mod)` loads `mod` from scratch, creating a new module object,
then replaces the old module object with the new one. As a consequence:

```julia
import A

st = A.SomeType(10)
reload("A")
st2 = A.SomeType(10)
typeof(st) == typeof(st2)   # false
```

`st` and `st2` are actually of a different type, and cannot be equal. Functions
defined on the first `::A.SomeType` will not work on the second, and vice
versa. This is inconvenient when working interactively.

`ClobberingReload.creload` solves this problem by never creating a second
module.  It just evaluates the modified code inside the existing module object,
replacing the previous definitions.

```julia
using ClobberingReload
import A

st = A.SomeType(10)
creload("A")
st2 = A.SomeType(10)
typeof(st) == typeof(st2)   # true
```

Furthermore, `reload` cannot reload modules imported via `using`, but `creload`
can.

Notes:

- `creload` will output a lot of redefinition warnings, since it is overwriting existing definitions. Relief coming soon!
- Parametric types cannot be _defined_  inside a `creload`ed module. (currently solved on Julia-master by [#17618](https://github.com/JuliaLang/julia/pull/17618), but not on 0.5.0). Using parametric types is fine.

## Dependencies

TODO: if A imports B and B changes, A should be reloaded after B.