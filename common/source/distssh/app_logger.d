/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh.app_logger;

import std.algorithm : among;
import std.stdio : writeln, writefln, stderr, stdout;

import logger = std.experimental.logger;
import std.experimental.logger : LogLevel;

class SimpleLogger : logger.Logger {
    this(const LogLevel lvl = LogLevel.warning) @safe {
        super(lvl);
    }

    override void writeLogMsg(ref LogEntry payload) @trusted {
        auto out_ = stderr;

        if (payload.logLevel.among(LogLevel.info, LogLevel.trace)) {
            out_ = stdout;
        }

        out_.writefln("%s: %s", payload.logLevel, payload.msg);
    }
}

class DebugLogger : logger.Logger {
    this(const logger.LogLevel lvl = LogLevel.trace) {
        super(lvl);
    }

    override void writeLogMsg(ref LogEntry payload) @trusted {
        auto out_ = stderr;

        if (payload.logLevel.among(LogLevel.info, LogLevel.trace)) {
            out_ = stdout;
        }

        out_.writefln("%s: %s [%s:%d]", payload.logLevel, payload.msg,
                payload.funcName, payload.line);
    }
}
