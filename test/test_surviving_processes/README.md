This test if the watchdog terminate leftover processes.

# Test Procedure

export DISTSSH_HOSTS=localhost
distssh -- make -j

In another console print the processes and look for the two sleep commands.
This is how it is expected to look like when running `pstree -u $USER -c|grep sleep -B10 -A10`
```
sshd---distcmd_recv---sh---make-+-sleep
                                `-sleep
```

kill the distssh process with -9.

Expected that the two sleep processe are terminated.
