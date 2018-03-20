# REQ-purpose

The purpose of this project is to provide automatic load balanced shells to the user.

# REQ-uc_shell
partof: REQ-purpose
###

The user wants an *interactive shell* on the *least loaded remote host* where he/she can do its daily work.

The user wants to logon to the server immediately. Therefore, the program will do this automatically.

# REQ-uc_remote_command
partof: REQ-purpose
###

The user wants to execute a *command* on the *least loaded remote host*.

**Note**: *command* can be a more or less complex string sent to the users prefered shell for execution.

The user experience should be as if the user ran it locally which probably affect how stdin/stdout/stderr is handled.
For now stdin is ignored.

# REQ-uc_check_all_hosts
partof: REQ-purpose
###

The user wants to execute *command* on all remote hosts.

## Why?

The user may want to inspect the remote hosts.

By having such a feature integrated in `distssh` it makes it easy for the user to reuse such features as sending over an environment to the remote hosts.

# REQ-uc_user_ctrl_of_remote_login
partof: REQ-purpose
###

It isn't wise to hardcode how ssh is used to login on a remote host. It may need other arguments, a specific key or even some other command than ssh.
Therefore the user wants to be able to control what *proxy command* is used and how it is used.

*proxy command*:
 * an example is how rsync does it: `rsync -e 'ssh -p22' .....`
   notice the `-e`.

## Investigate

Maybe an environment variable should be used too? I think ssh do that. It wouldn't hurt.
It would make it possible to centrally change/control the default but still allow the user to override.

# REQ-fast_experience
partof: REQ-purpose
###

The overhead of running a *command* via `distssh` shall be at most 2 seconds.

The overall goal that must be fulfilled is that the program shall always be fast and succeed. The user **must** feel that the program can be used for any use case.
The user should never have to really think of different use cases such as:
 * "I think this command is lightweight so I run it normally"
 * compared to
 * "I know this command is heavy weight so I should use the program"

*There should be one way that always work and it is the right way.*

Running a command on a remote host over ssh can be slow.
The program should implement strategies to lower the overhead.

It is important that the edit-compile-execute cycle is kept fast and efficient.

*Interactive shell*:
 * The important aspect is that the program either succeed in spawning a shell on a remote host or print a *helpful* error message to the user.
 * This implies that it shouldn't stop just because one of the remote hosts are unavailable.
 * Or one of the remote hosts are down and because of timeouts it feels for the user as if the program stopped/hanged/failed.

*least loaded remote host Cache*:
 * The program should try and avoid having to login on the servers for every little command that is ran.
   This creates unnecessary overhead.
   The program should therefore use a local cache that is updated *when suitable*.
   This should give the user experience that most commands are just fast.
   That the program have "warm up" time

## Why 2 seconds?

I chose the number because after 2s I myself become annoyed. This may need further investigation.

# SPC-best_remote_host
partof: REQ-purpose
###

The *least loaded remote host* shall be calculated from the available servers.

Pseudo code for calculating the *least loaded remote host*:
 * Check load on all available server. See [[SPC-measure_local_load]] for details of load calculation
   Use a 2s timeout by default to make sure it doesn't affect the user too much if one server is slow.
 * Choose at random one of the three servers with the lowest loadavg.

# SPC-measure_remote_hosts
partof: SPC-best_remote_host
###

The program shall print the measurements of all remote hosts on user command.

## Why?
Because it makes it possible to find bottlenecks among the remote hosts.
Makes it possible to adjust the default timeout to a sane value.

TODO: consider if the default timeout should be configurable.

# SPC-measure_local_load
partof: SPC-best_remote_host
###

The program shall print the load of the local host when commanded.

The program shall calculate the load as the *5min loadavg* / *available cores*.

**Rationale**: The guidline is that a loadavg that is greater than the available cores on the server mean the server is overloaded. By normalizing the value the load can be used to compare the *load* of servers where the number of cores are different.

## Info

I chose the 5min average just because it is the first value when reading from `/proc/loadavg`.
No other reason than that.

This should probably be investigated further.

## Why use distssh for this?

To avoid a dependency on e.g. *cat* and enable future improvements to load calculation the absolute path to *distssh* is used.

The negative thing is that it assumes/requires *distssh* to be installed at the same path on the remote as on the local machine.

# SPC-remote_shell_config
partof: REQ-uc_user_ctrl_of_remote_login
###

The program shall use the argument from the CLI option `-e` when logging in on the *remote host*.

The program shall use `ssh -oStrictHostKeyChecking=no` as the default for `-e`.

# SPC-load_balance_heavy_commands
partof: REQ-uc_remote_command
###

The program shall distribute the command from the user to a *least loaded remote host* when the command is in the environ variable DISTSSH_CMD.

# SPC-fast_env_startup
partof: REQ-uc_fast_experience
###

The program shall store the current environment to *env file* when the user CLI is `--export-env`.

The program shall setup the env from *env file* if it exists when running a user command.

## Why?
The environment can be slow to startup if e.g. .bashrc has to run.

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

# SPC-remote_command_parse
partof: REQ-uc_remote_command
###

The program shall run the *command* on the *least loaded remote host* by default when the user execute the program.
 * The arguments to use are either:
     * those left after distssh has parsed the command line
     * those that are after the `--`

The program shall run the *command* on the *least loaded remote host* when the program name (`args[0]`) is `distcmd`.
 * The arguments to use are `args[1 .. $]`

## Why?

Why the complication with what arguments to use when running on the remote host?

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

*Non-interactive shell*:
 * This is commands that are ran but not directly by the user.
   This could be for example make calling the shell.
   The program should in this case intercept configured commands and distribute those over servers.

# SPC-early_terminate_no_processes_left
partof: REQ-uc_remote_command
###

The program shall terminate all remote processes when the local distssh process is killed with SIGKILL.

## Why?

It is a problem that remote programs that end up in an infinite loop are left behind, fork or such a simple thing as `sleep 20&`.

## Notes

The implementation do not have to be perfect but it should try and cover most cases.

The implementation can ignore the case of a process that try to daemonize. It is practically impossible to solve without root privileges which contain the processes because the parent process is changed to init.

# TST-early_terminate_no_processes_left
partof: SPC-early_terminate_no_processes_left
done: manual procedure
###

*Note*: This test procedure has to be executed manually.

*Precondition*:
 * the tool is built.
 * the tester is in the directory `test/test_surviving_processes`
 * the remote host variable is `export DISTSSH_HOSTS=localhost`
 * a makefile with at least two targets that *sleep*

*input*:
 * same process group, command `make -j`
 * run two process groups, command `'make -j & time sleep 60'`
   TODO distssh is not fully working as expected for this input. It should *wait* 60s but it terminates almost immediately
 * new process group `immediatly_new_process_group.sh`
 * new session `new_session.sh`

*Verification command*:
 * `pstree -u joker -pcg|grep -A 10 -B 10 -i ssh`

Expected result when executing *input* on the remote host.

Procedure:
 * Run the command `../../build/distssh -- ` *input*
 * Run the *Verification command* (two sleeping processes)
 * Kill the client side of distssh with SIGKILL
 * Expected result when running the *Verification command*

## Example output

Before killing distssh.
```sh
sshd(11064,11011)---distssh(11065,11065)---sh(11066,11065)---make(11067,11065)-+-sleep(11068,11065)
                                                                               `-sleep(11069,11065)
```

# SPC-shell_current_dir
partof: REQ-uc_shell
###

The program shall set the current working directory to the same as on the host side if it exists when logging in on the *least loaded remote host*.

## Why?

It is on the assumption that the user want to do operations with tools that only exist on the remote host.
By setting the working directory to the same as on the host it mean that the user do not have to `cd` to the directory.
The user can start working right away.

# SPC-remote_shell
partof: REQ-uc_shell
###

The program shall give the user an interactive shell on the *least loaded remote host* when commanded via CLI

# SPC-sigint_detection
partof: SPC-uc_remote_command
###

The program shall shutdown the remote end *fast* when a SIGINT is received.

# Notes

A SIGINT on the remote end is propagated over the connection to the remote host by the sshd instance terminating.
This mean that the parent process of distssh changes from X to init (1) on such an event.

By continuous checking the parent pid it is thus possible to reliable detect when the SIGINT is received.

# TST-sigint_detection
partof: SPC-sigint_detection
done: manual procedure
###

*Note*: This test procedure has to be executed manually.

*Precondition*:
 * the tool is built.
 * the tester is in the directory `test/test_surviving_processes`
 * the remote host variable is `export DISTSSH_HOSTS=localhost`
 * a makefile with at least two targets that *sleep*

*input*:
 * same process group, command `make -j`

*Verification command*:
 * `pstree -u joker -pcg|grep -A 10 -B 10 -i ssh`

Expected result when executing *input* on the remote host.

Procedure:
 * Run the command `../../build/distssh -- ` *input*
 * Run the *Verification command* (two sleeping processes)
 * Kill the client side of distssh with ctrl+C (SIGINT)
 * Expected result when running the *Verification command*

# SPC-flush_buffers
partof: REQ-uc_check_all_hosts
###

The program shall flush stdout before running a *command* on a remote host.

## Why?

Ssh will write to stdout but it is flushed compared to internal logging that isn't.
Thus the logging text from `distssh` itself may end up out of order.

# SPC-list_of_remote_hosts
partof: REQ-purpose
###

The program shall read the list of remote hosts from the environment variable `DISTSSH_HOSTS`.

# SPC-fallback_remote_host
partof: REQ-uc_shell
###

The program shall on a failure to login on the remote host continue with the next one in the list of *least loaded hosts*.

# Info

I don't know how to reliably detect that the ssh connection failed because of a remote host that didn't answer without capturing stdout and textually analyze it.
This would in turn have other bad side effects such an increased computation or possibility for erronious *detection* because the user *printed* something that gets mixed up with ssh's output.

As a workaround the timeout * 2 is used.
If the connection isn't interrupted in that timeframe it is assumed it worked OK.
This is also based on the fact that a load check has already been done.

## Why?

The user really, really want a shell. A remote host may be down or otherwise in a bad shape so try and login until there are none left.

# SPC-remote_command_pretty_colors
partof: REQ-uc_remote_command
###

The program shall force the remote host to emulate a tty when the user run the command via a tty.

**Rationale**: This gives the user pretty coloers when the command is ran in a console.

**Rationale**: It improves the feeling of running a remote command is *as if* it ran locally.
