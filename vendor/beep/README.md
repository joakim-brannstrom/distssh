beep [![Repository](https://img.shields.io/badge/repository-on%20GitLab-orange.svg)](https://gitlab.com/AntonMeep/beep) [![pipeline 
status](https://gitlab.com/AntonMeep/beep/badges/master/pipeline.svg)](https://gitlab.com/AntonMeep/beep/commits/master) [![coverage 
report](https://gitlab.com/AntonMeep/beep/badges/master/coverage.svg)](https://gitlab.com/AntonMeep/beep/commits/master) [![MIT 
Licence](https://img.shields.io/badge/licence-MIT-blue.svg)](https://gitlab.com/AntonMeep/beep/blob/master/LICENCE) [![Package 
version](https://img.shields.io/dub/v/beep.svg)](https://gitlab.com/AntonMeep/beep/tags)
=====

**beep** is an advanced assertion library which provides light and simple alternative to built-in `assert`s to be used in unit-tests.

> Note that project's development happens on the [GitLab](https://gitlab.com/AntonMeep/beep).
> GitHub repository is a mirror, it might *not* always be up-to-date.

```D
version(unittest) import beep;

unittest {
	1.expect!equal(1);
	"Hello, World!".expect!contain("World");
}
```

## API

API consists of different `expect` overloads which take 1 or 2 arguments and an operation to be performed on those arguments. Most of the `expect` overloads return first value passed to them (unless otherwise is noted), allowing you to perform multiple checks at once:

```D
1.expect!less(2)
	.expect!greater(0);
```

### `expect!(OP, T1, T2)(T1 a, T2 b) if(is(OP == equal))`

Checks if `a` is equal to `b`

*Example*:
```D
1.expect!equal(1);
"Hello!".expect!equal("Hi!"); // Fails
```

*Parameters*: Any values that can be compared (i.e. define 'opEquals')

### `expect!(bool b, T1)(T1 a)`

Shorthand for `expect!(equal, T1, bool)(a, b)`

*Example*:
```D
true.expect!true;
0.expect!false;
```

*Parameters*: Any values

### `expect!(OP, T1, T2)(T1 a, T2 b) if(is(OP == less))`

Checks if `a` is less than `b`

*Example*:
```D
1.expect!less(2);
"aa".expect!less("bb");
```

*Parameters*: Any values that can be compared (i.e. define 'opCmp')

### `expect!(OP, T1, T2)(T1 a, T2 b) if(is(OP == greater))`

Checks if `a` is greater than `b`

*Example*:
```D
100.expect!greater(2);
"cc".expect!greater("bb");
```

*Parameters*: Any values that can be compared (i.e. define 'opCmp')

### `expect!(typeof(null), T1)(T1 a)`

Checks if `a` is `null`

*Example*:
```D
null.expect!null;

void delegate() func;
func.expect!null;
```

*Parameters*: Any values that can be checked with `a is null`

### `expect!(OP, T1, T2)(T1 a, T2 b) if(is(OP == contain))`

Checks if `b` can be found in `a`

*Example*:
```D
[1,2,3].expect!contain(1);
"Hello, World!".expect!contain("World")
	.expect!contain('!');
```

*Parameters*: Any values that can be passed to [`std.algorithm.searching.canFind(a, b)`](https://dlang.org/phobos/std_algorithm_searching.html#.canFind)

### `expect!(OP, T1, T2)(T1 a, T2 b) if(is(OP == match))`

Checks if `a` matches regular expression `b`

*Example*:
```D
"12345".expect!match(r"\d\d\d\d\d");
"abc".expect!match(r"\w{3}");
```

*Parameters*: Any values that can be passed to [`std.regex.matchFirst(a, b)`](https://dlang.org/phobos/std_regex.html#.matchFirst)


### `expect!(OP, E : Exception = Exception, T1)(T1 a) if(is(OP == throw_))`

Checks if `a();` throws an exception of type `E` or any exception that is derived from `E`. By default it will catch any exception.

*Example*:
```D
(() {
	throw new Exception("Hello!");
}).expect!throw_;
```

*Parameters*: `a` should be a callable function, delegate, or struct/class which defines `opCall`

*Returns*: Tuple of `data` which contains `a` and `message` which contains message of the exception.
