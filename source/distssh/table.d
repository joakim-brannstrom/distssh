/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh.table;

import logger = std.experimental.logger;
import std.exception : collectException;

@safe:

struct Table(int columnsNr) {
    alias Row = string[columnsNr];

    Row heading_;
    Row[] rows;
    ulong[columnsNr] columnWidth;

    this(const Row heading) {
        this.heading = heading;
        updateColumns(heading);
    }

    void heading(const Row r) {
        heading_ = r;
        updateColumns(r);
    }

    void put(const Row r) {
        rows ~= r;
        updateColumns(r);
    }

    import std.format : FormatSpec;

    void toString(Writer, Char)(scope Writer w, FormatSpec!Char fmt) const {
        import std.ascii : newline;
        import std.range : enumerate, repeat;
        import std.format : formattedWrite;
        import std.range.primitives : put;

        immutable sep = "|";
        immutable lhs_sep = "| ";
        immutable mid_sep = " | ";
        immutable rhs_sep = " |";

        void printRow(const ref Row r) {
            foreach (const r_; r[].enumerate) {
                if (r_.index == 0)
                    put(w, lhs_sep);
                else
                    put(w, mid_sep);
                formattedWrite(w, "%-*s", columnWidth[r_.index], r_.value);
            }
            put(w, rhs_sep);
            put(w, newline);
        }

        printRow(heading_);

        immutable dash = "-";
        foreach (len; columnWidth) {
            put(w, sep);
            put(w, repeat(dash, len + 2));
        }
        put(w, sep);
        put(w, newline);

        foreach (const ref r; rows) {
            printRow(r);
        }
    }

    private void updateColumns(const ref Row r) nothrow {
        import std.algorithm : filter, count, map;
        import std.range : enumerate;
        import std.uni : byGrapheme;
        import std.typecons : tuple;

        try {
            foreach (a; r[].enumerate
                    .map!(a => tuple(a.index, a.value.byGrapheme.count))
                    .filter!(a => a[1] > columnWidth[a[0]])) {
                columnWidth[a[0]] = a[1];
            }
        } catch (Exception e) {
            logger.warning(e.msg).collectException;
        }
    }
}
