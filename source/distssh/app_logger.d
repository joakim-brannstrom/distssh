/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh.app_logger;

import std.algorithm : among;
import std.stdio : writeln, writefln, stderr, stdout;

import logger = std.experimental.logger;

class SimpleLogger : logger.Logger {
    import std.conv;

    int line = -1;
    string file = null;
    string func = null;
    string prettyFunc = null;
    string msg = null;
    logger.LogLevel lvl;

    this(const logger.LogLevel lv = logger.LogLevel.trace) {
        super(lv);
    }

    override void writeLogMsg(ref LogEntry payload) @trusted {
        this.line = payload.line;
        this.file = payload.file;
        this.func = payload.funcName;
        this.prettyFunc = payload.prettyFuncName;
        this.lvl = payload.logLevel;
        this.msg = payload.msg;

        auto out_ = stderr;

        if (payload.logLevel.among(logger.LogLevel.info, logger.LogLevel.trace)) {
            out_ = stdout;
        }

        out_.writefln("%s: %s", text(this.lvl), this.msg);
    }
}
