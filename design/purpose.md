# REQ-purpose

The purpose of this project is to provide automatic load balanced shells to the user.

# REQ-uc_shell
partof: REQ-purpose
###

The user want an *interactive shell* on the *best remote host* where he/she can do its daily work.

For this to work the program need to login on the server. It isn't really useful if it would just print out which server it is.

# REQ-uc_remote_command
partof: REQ-purpose
###

The user wants to execute *command* on the *best remote host*.

The user experience should be as if the user ran it locally which probably affect how stdin/stdout/stderr is handled.
For now stdin is ignored.

# REQ-uc_check_all_hosts
partof: REQ-purpose
###

The user wants to execute *command* on all remote hosts.

## Why?

The user may want to inspect the remote hosts. This is an easy way and interface to do that. It makes it possible to reuse such features as loading of the environment.

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

# REQ-uc_fast_experience
partof: REQ-purpose
###

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

*Best Remote Host Cache*:
 * The program should try and avoid having to login on the servers for every little command that is ran.
   This creates unnecessary overhead.
   The program should therefore use a local cache that is updated *when suitable*.
   This should give the user experience that most commands are just fast.
   That the program have "warm up" time

# SPC-best_remote_host
partof: REQ-purpose
###

The *best remote host* shall be calculated from the available servers.

Pseudo code for calculating the *best remote host*:
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

The program shall distribute the command from the user to a *best remote host* when the command is in the environ variable DISTSSH_CMD.

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

The program shall run the *command* on the *best remote host* by default when the user execute the program.
 * The arguments to use are either:
     * those left after distssh has parsed the command line
     * those that are after the `--`

The program shall run the *command* on the *best remote host* when the program name (`args[0]`) is `distcmd`.
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
