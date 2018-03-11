# REQ-purpose

The purpose of this project is to provide automatic load balanced shells to the user.

# REQ-uc_shell
partof: REQ-purpose
###

The user want an *interactive shell* on the *best remote host* where he/she can do its daily work.

*Info*: For this to work the program need to login on the server. It isn't really useful if it would just print out which server it is.

# SPC-best_remote_host
partof: REQ-uc_shell
###

The *best remote host* shall be calculated from the available servers.

Pseudo code for calculating the *best remote host*:
 * Check the 5min load on all available server.
   Use a 3s timeout to make sure it doesn't affect the user too much if one server is slow.
 * Choose at random one of the three servers with the lowest loadavg.

## Info
A simple way of choosing the best server is to check the load average.

I chose the 5min average just because it is the first value when reading from `/proc/loadavg`.
No other reason than that.

This should probably be investigated further.

# REQ-uc_remote_command
partof: REQ-purpose
###

The user want a *command* to be executed on the *best remote host*.

The user experience should be as if the user ran it locally which probably affect how stdin/stdout/stderr is handled.
For now stdin is ignored.

# REQ-uc_user_ctrl_of_remote_login
partof: REQ-purpose
###

It isn't wise to hardcode how ssh is used to login on the remote server. It may need other arguments, a specific key or even some other command than ssh.
Therefore the user wants to be able to control what *proxy command* is used and how it is used.

*proxy command*:
 * an example could is how rsync do it: `rsync -e 'ssh -p22' .....`
   notice the `-e`.

## Investigate

Maybe an environment variable should be used too? I think ssh do that. It wouldn't hurt.
It would make it possible to centrally change/control the defaul but still allow the user to override.

# SPC-remote_shell_config
partof: REQ-uc_user_ctrl_of_remote_login
###

The program shall use the argument from the CLI option `-e` when logging in on the *remote host*.

The program shall use `ssh -oStrictHostKeyChecking=no` as the default for `-e`.

# SPC-load_balance_heavy_commands
partof: REQ-uc_shell
###

The program shall distribute the command from the user to a *best remote host* when the command is in the environ variable DISTSSH_CMD.

# REQ-uc_fast_experience
partof: REQ-uc_shell
###

Running a command on a remote host over ssh can be slow. The program should implement a strategy to handle it in such a way that the overhead of using the program is *low*.

The overall goal that must be fulfilled is that the program shall always be fast and succeed. The user **must** feel that the program can be used for any use case.
The user should never have to really think of different use cases such as "I think this command is lightweight so I run it normally" compared to "I know this command is heavy weight so I should use the program".

There should be one way that always work and is fast.

Low need to be split in two categories to be useful.

*Interactive shell*:
 * The important aspect is that the program should always succeed in spawning a shell.
   This implicit that it shouldn't stop just because one of the remote hosts are unavailable.
   Or one of the remote hosts are down and because of timeouts it feels for the user as if the program stopped/hanged/failed.

*Best Remote Host Cache*:
 * The program should try and avoid having to login on the servers for every little command that is ran.
   This creates unnecessary overhead.
   The program should therefore use a local cache that is updated *when suitable*.
   This should give the user experience that most commands are just fast.
   That the program have "warm up" time

*Non-interactive shell*:
 * This is commands that are ran but not directly by the user.
   This could be for example make calling the shell.
   The program should in this case intercept configured commands and distribute those over servers.

*Env Startup*:
 * The environment can be slow to startup if e.g. .bashrc has to run.
   One way of speeding up this is to make a copy of the environment variables and "load" them on the target computer.
   This probably work well if the host and remote host is similar enough.

# SPC-meta_design
partof: REQ-purpose
###

This is a meta-design requirement for design decision that can't directly be traced to a requirement.

# SPC-ssh_relaxed_remote_host
partof: SPC-meta_design
###

The program shall use the flag `-oStrictHostKeyChecking=no` when logging in via ssh.

## Why?
It is probable the case that the user hasn't logged on to all remote hosts.
It can be assumed that the environment variable holding the remote hosts are safe thus this is not a strictly needed check.

It is thus relaxed to reduce/remove the dump of junk in the console and make more hosts available to the user.

It assumes that this program is used on a closed network.
If it is used over internet.... this should be changed.

# SPC-load_balance
partof: REQ-uc_shell
###

The load balance is static after the login. This may be problematic if many users end up on the same server because the program do not do "live migration".

# SPC-remote_command
partof: REQ-uc_remote_command
###

The program shall run the *command* on the *best remote host* by default when the user execute the program.
 * The arguments to use are either:
     * those left after distssh has parsed the command line
     * those that are after the `--`

The program shall run the *command* on the *best remote host* when the program name (`args[0]`) is `distcmd`.
 * The arguments to use are `args[1 .. $]`

## Why?

Why the compliation with what arguments to use when running on the remote host?

It is because there may exist program which have the same arguments as those used by distssh.
If there are no way of avoiding distssh command line parsing these commands could become unusable.

By having a dedicated command for just this, `distcmd`, it becomes easy to integrate in scripts.

# SPC-draft_remote_cmd_spec
partof: REQ-purpose
###

The design is such that the environment is exported on command from the user.
This means that it is not always done.

The command on the receiving end is a symlinked version of distssh that know that it should try and configure the environemnt variables from a file, if it exists, before running the command.

Thus the process of launching a remote process is a multi stage rocket.
 * store the env to a file, if the user uses `--export-env`
 * choose a host with the lowest load
 * ssh to the remote host with a the command:
   `distcmd_env` `current working directory` `path to env file` `the user commands`
 * when logged in on the remote host `distcmd_env` triggers which:
    * read the env from the file
    * runs the user command with the configured env
