# ClobberingReload

[![Build Status](https://travis-ci.org/cstjean/ClobReload.jl.svg?branch=master)](https://travis-ci.org/cstjean/ClobReload.jl)

[![Coverage Status](https://coveralls.io/repos/cstjean/ClobReload.jl/badge.svg?branch=master&service=github)](https://coveralls.io/github/cstjean/ClobReload.jl?branch=master)

[![codecov.io](http://codecov.io/github/cstjean/ClobReload.jl/coverage.svg?branch=master)](http://codecov.io/github/cstjean/ClobReload.jl?branch=master)

ClobberingReload provides a `reload` alternative that may be more convenient
for your workflow, as well as functionality for automatically reloading
modified modules. It is a direct successor to **@malmaud**'s
[Autoreload.jl](https://github.com/malmaud/Autoreload.jl)
(in fact, it aims to be a straight replacement), and borrows ideas from
[atom-julia-client](https://github.com/JunoLab/atom-julia-client)

## Installation

ClobberingReload is not yet registered in METADATA. Install with

```julia
Pkg.clone("git://github.com/cstjean/ClobberingReload.jl.git")
```

and please report any issues you encounter.

## Clobbering Reload

Julia's `reload` loads the module from scratch, creating a new module object.
then replaces the old module with the new one. As a consequence, in code like
this:

```julia
import A

st = A.SomeType(10)
reload("A")
st2 = A.SomeType(10)
typeof(st) == typeof(st2)   # false
```

`st` and `st2` are actually of a different type. Functions defined on the
first `A.SomeType` will not work on the second, and vice versa. This is
inconvenient when working interactively.

`ClobberingReload` solves this problem by never creating a second module.
It just evaluates the modified code inside the existing module object,
replacing the previous definitions. Types are left as is.

```julia
using ClobberingReload
import A

st = A.SomeType(10)
creload("A")
st2 = A.SomeType(10)
typeof(st) == typeof(st2)   # true
```

Furthermore, `reload` cannot reload modules imported via `using`, but `creload`
works fine.

## Autoreload

In [IJulia](https://github.com/JuliaLang/IJulia.jl), `creload` will be called
automatically for modules that were imported using `@ausing` or `@aimport`,
whenever the module's source has been changed.
Example:

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

## Dependencies

TODO: if A imports B and B changes, A should be reloaded after B.