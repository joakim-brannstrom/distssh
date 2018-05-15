/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This module contains libc bindings.
*/
module distssh.libc;

/**
DESCRIPTION

     The getloadavg() function returns the number of processes in the system
     run queue averaged over various periods of time.  Up to nelem samples are
     retrieved and assigned to successive elements of loadavg[].  The system
     imposes a maximum of 3 samples, representing averages over the last 1, 5,
     and 15 minutes, respectively.


DIAGNOSTICS

     If the load average was unobtainable, -1 is returned; otherwise, the num-
     ber of samples actually retrieved is returned.
 */
extern (C) int getloadavg(double* loadavg, int nelem);

extern (C) int forkpty(int* master, char* name, void* termp, void* winp) nothrow;
extern (C) char* ttyname(int fd) nothrow;
