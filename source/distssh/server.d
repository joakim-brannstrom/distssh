/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This is the server that is running in the background surveying the cluster for
performance.
*/
module distssh.server;

import distssh.main_ : Options;

int serverGroup(const Options opts) nothrow {
    return 0;
}
