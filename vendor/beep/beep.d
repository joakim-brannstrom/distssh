module beep;

import std.format : format;

enum equal;
enum less;
enum greater;
enum contain;
enum match;
enum throw_;

final class ExpectException : Exception {
	pure nothrow @safe this(string msg,
								  string file = __FILE__,
								  size_t line = __LINE__,
								  Throwable nextInChain = null) {
		super("Expectation failed: " ~ msg, file, line, nextInChain);
	}
}

struct Fence {}

T1 expect(OP, T1, T2)(lazy T1 lhs, lazy T2 rhs, Fence _ = Fence(), string file = __FILE__, size_t line = __LINE__)
if(is(OP == equal) && __traits(compiles, lhs == rhs)) {
	if(!(lhs == rhs))
		throw new ExpectException(
			"`%s` is expected, got `%s`".format(rhs, lhs),
			file,
			line,
		);

	return lhs;
}

@("expect!equal")
@safe pure unittest {
	1.expect!equal(1);
	"Hi!".expect!equal("Hi!");

	struct S {
		int* ptr;
	}

	S(null).expect!equal(S(null));
}

@("expect!equal checks can be chained")
@safe pure unittest {
	1.expect!equal(1)
		.expect!equal(1)
		.expect!equal(1);
}

@("expect!equal fails if value is not equal to expected value")
unittest {
	({
		1.expect!equal(2);
	}).expect!(throw_, ExpectException)
		.message.expect!contain("`2` is expected, got `1`");

	({
		"Hello, Alice!".expect!equal("Hello, Bob!");
	}).expect!(throw_, ExpectException)
		.message.expect!contain("`Hello, Bob!` is expected, got `Hello, Alice!`");

	({
		struct S {
			string s;
			int n;
		}

		S("Hi!", 42).expect!equal(S("Bye!", 43));
	}).expect!(throw_, ExpectException)
		.message.expect!contain("`S(\"Bye!\", 43)` is expected, got `S(\"Hi!\", 42)`");
}

T1 expect(bool bool_, T1)(lazy T1 lhs, Fence _ = Fence(), string file = __FILE__, size_t line = __LINE__) {
	return expect!(equal, T1)(lhs, bool_, _, file, line);
}

@("expect!(true|false) - convenience wrapper around expect!equal")
@safe pure unittest {
	1.expect!true;
	0.expect!false;
}

@("expect!(true|false) checks can be chained")
@safe pure unittest {
	1.expect!true
		.expect!true
		.expect!true;

	0.expect!false
		.expect!false
		.expect!false;
}

@("expect!(true|false) fails if value is not true|false")
unittest {
	({
		0.expect!true;
	}).expect!(throw_, ExpectException)
		.message.expect!contain("`true` is expected, got `0`");

	({
		1.expect!false;
	}).expect!(throw_, ExpectException)
		.message.expect!contain("`false` is expected, got `1`");
}

T1 expect(OP, T1, T2)(lazy T1 lhs, lazy T2 rhs, Fence _ = Fence(), string file = __FILE__, size_t line = __LINE__)
if(is(OP == less) && __traits(compiles, lhs < rhs)) {
	if(!(lhs < rhs))
		throw new ExpectException(
			"value less than `%s` is expected, got `%s`".format(rhs, lhs),
			file,
			line,
		);

	return lhs;
}

@("expect!less")
@safe unittest {
	1.expect!less(2);
	1.0.expect!less(1.00001);
}

@("expect!less checks can be chained")
@safe pure unittest {
	1.expect!less(2)
		.expect!less(3)
		.expect!less(4)
		.expect!less(5)
		.expect!less(6);
}

@("expect!less fails if one value is not less than expected")
unittest {
	({
		1.expect!less(2)
			.expect!less(3)
			.expect!less(4)
			.expect!less(0);
	}).expect!(throw_, ExpectException)
		.message.expect!contain("value less than `0` is expected, got `1`");
}

T1 expect(OP, T1, T2)(lazy T1 lhs, lazy T2 rhs, Fence _ = Fence(), string file = __FILE__, size_t line = __LINE__)
if(is(OP == greater) && __traits(compiles, lhs > rhs)) {
	if(!(lhs > rhs))
		throw new ExpectException(
			"value greater than `%s` is expected, got `%s`".format(rhs, lhs),
			file,
			line,
		);

	return lhs;
}

@("expect!greater")
@safe unittest {
	1.expect!greater(0);
	1.001.expect!greater(1);
}

@("expect!greater checks can be chained")
@safe pure unittest {
	1.expect!greater(0)
		.expect!greater(-1)
		.expect!greater(-2)
		.expect!greater(-3)
		.expect!greater(-4)
		.expect!greater(-5);
}

@("expect!greater fails if one value is not greater than expected")
unittest {
	({
		1.expect!greater(0)
			.expect!greater(-1)
			.expect!greater(2);
	}).expect!(throw_, ExpectException)
		.message.expect!contain("value greater than `2` is expected, got `1`");
}

T1 expect(typeof(null) null_, T1)(lazy T1 lhs, Fence _ = Fence(), string file = __FILE__, size_t line = __LINE__) {
	if(lhs !is null)
		throw new ExpectException(
			"null is expected, got `%s`".format(lhs),
			file,
			line,
		);

	return lhs;
}

@("expect!null")
@safe pure unittest {
	void delegate() func;
	func.expect!null;

	null.expect!null;
}

@("expect!null fails if value is not null")
unittest {
	({
		void delegate() func = () {};

		func.expect!null;
	}).expect!(throw_, ExpectException)
		.message.expect!contain("null is expected, got `void delegate()`");

	({
		auto v = true;
		(&v).expect!null;
	}).expect!(throw_, ExpectException)
		.message.expect!match("null is expected, got `.*`");
}

T1 expect(OP, T1, T2)(lazy T1 lhs, lazy T2 rhs, Fence _ = Fence(), string file = __FILE__, size_t line = __LINE__)
if(is(OP == contain) && __traits(compiles, {import std.algorithm.searching : canFind; lhs.canFind(rhs);})) {
	import std.algorithm.searching : canFind;
	if(!lhs.canFind(rhs))
		throw new ExpectException(
			"value is expected to contain `%s`, got `%s`".format(rhs, lhs),
			file,
			line,
		);

	return lhs;
}

@("expect!contain")
@safe pure unittest {
	"Hello, World!".expect!contain("World");
	[1,2,3].expect!contain(1);
	[[1,2],[2,3],[4,5]].expect!contain([1,2]);
}

@("expect!contain checks can be chained")
@safe pure unittest {
	"Hello, World!".expect!contain("World")
		.expect!contain("Hello")
		.expect!contain('!')
		.expect!contain(',')
		.expect!contain(' ');
}

@("expect!contain fails if value does not contain expected data")
unittest {
	({
		"Hello, World!".expect!contain("Hi!");
	}).expect!(throw_, ExpectException)
		.message.expect!contain("value is expected to contain `Hi!`, got `Hello, World!`");

	({
		[1,2,3].expect!contain(4);
	}).expect!(throw_, ExpectException)
		.message.expect!contain("value is expected to contain `4`, got `[1, 2, 3]`");
}

T1 expect(OP, T1)(lazy T1 lhs, string re, Fence _ = Fence(), string file = __FILE__, size_t line = __LINE__)
if(is(OP == match) && __traits(compiles, {import std.regex : matchFirst; matchFirst(lhs, re);})) {
	import std.regex : matchFirst;
	if(lhs.matchFirst(re).empty)
		throw new ExpectException(
			"value matching `%s` is expected, got `%s`".format(re, lhs),
			file,
			line,
		);

	return lhs;
}

@("expect!match")
@safe unittest {
	"12345".expect!match(r"\d\d\d\d\d");
	"abc".expect!match(r"\w{3}");
}

@("expect!match checks can be chained")
@safe unittest {
	"123abc".expect!match(r"\d\d\d\w\w\w")
		.expect!match(r"\d{3}.*")
		.expect!match(r"[1-3]+[a-c]+");
}

@("expect!match fails if value does not match provided regex")
unittest {
	({
		"123".expect!match(r"abc");
	}).expect!(throw_, ExpectException)
		.message.expect!contain("value matching `abc` is expected, got `123`");
}

auto expect(OP, E : Exception = Exception, T1)(lazy T1 lhs, Fence _ = Fence(), string file = __FILE__, size_t line = __LINE__)
if(is(OP == throw_) && __traits(compiles, {lhs(/+_+/)(/*_*/);})) {
	struct Result {
		T1 data;
		string message;
	}

	Result r = Result(lhs);

	try {
		lhs()();
	} catch(Exception e) {
		if(!(cast(E) e))
			throw new ExpectException(
				"`%s` is expected to be thrown, an exception of type `%s` has been thrown instead".format(
					typeid(E).name,
					typeid(e).name),
				file,
				line,
				e,
			);

		r.message = e.message.idup;
		return r;
	}

	throw new ExpectException(
		"`%s` is expected to be thrown but nothing has been thrown".format(typeid(E).name),
		file,
		line,
	);
}

@("expect!throw_")
unittest {
	(() {
		throw new Exception("Hello!");
	}).expect!throw_;
}

@("expect!(throw_, CustomException)")
unittest {
	final class CustomException : Exception {
		pure nothrow @nogc @safe this(string msg) {
			super(msg);
		}
	}

	({
		throw new CustomException("message");
	}).expect!(throw_, CustomException);

	({
		throw new CustomException("message");
	}).expect!(throw_, Exception);

	({
		({
			throw new Exception("message");
		}).expect!(throw_, CustomException);
	}).expect!(throw_, ExpectException);
}

@("expect!throw_ returns a tuple of the input data and message of the exception that has been thrown")
unittest {
	auto func = ({
		throw new Exception("Hello!");
	});
	
	auto result = func.expect!throw_;

	(func is result.data).expect!equal(true);
	result.message.expect!equal("Hello!");
}

@("expect!throw_ does *not* catch Errors")
unittest {
	import core.exception : AssertError;

	bool success;
	try {
		({
			assert(false);
		}).expect!throw_;
	} catch(AssertError e) { // This is something nobody should ever do
		success = true;
	}

	success.expect!equal(true);
}

@("expect!throw_ fails when nothing has been thrown")
unittest {
	({
		({
			1.expect!true;
		}).expect!throw_;
	}).expect!(throw_, ExpectException)
		.message.expect!contain("`object.Exception` is expected to be thrown but nothing has been thrown");
}