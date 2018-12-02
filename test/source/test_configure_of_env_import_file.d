/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

#TST-test_configure_env_import_file
*/
module test_configure_env_import_file;

import config;

shared(bool) g_preCondition;

auto preCondition(string test_area) {
    prepareDistssh;

    immutable script = `#!/bin/bash
echo "smurf is $SMURF"`;

    // arrange
    const script_file = buildPath(test_area, "foo.sh");
    string[string] fake_env;

    // action
    File(script_file, "w").write(script);
    synchronized {
        if (!g_preCondition) {
            g_preCondition = true;
            fake_env["SMURF"] = "42";
            assert(spawnShell(distssh ~ " --export-env", stdin, stdout, stderr,
                    fake_env).wait == 0, "failed to export env");
        }
    }

    return script_file;
}

@(
        "shall print the environment variable that is part of the export when executing on the remote host")
unittest {
    // arrange
    auto area = TestArea(__FILE__, __LINE__);
    const script_file = preCondition(area);

    // action
    auto res = executeShell(distssh ~ " --local-run -- bash " ~ script_file);

    // assert
    assert(res.status == 0, "failed executing: " ~ res.output);
    assert(res.output.canFind("42"),
            "failed finding 42 which should have been part of the imported env");
}

@("shall NOT import the environment from the default file")
unittest {
    // arrange
    auto area = TestArea(__FILE__, __LINE__);
    const script_file = preCondition(area);

    // action
    auto res = executeShell(distssh ~ " --no-import-env --local-run -- bash " ~ script_file);

    // assert
    assert(res.status == 0, "failed executing: " ~ res.output);
    assert(!res.output.canFind("42"), "env imported when it shouldn't have been");
}

@("shall import the env from the specified file specified via CLI")
unittest {
    // arrange
    auto area = TestArea(__FILE__, __LINE__);
    const script_file = preCondition(area);

    // action
    auto fake_env = ["SMURF" : "43"];
    const env_file = buildPath(area, "myenv.export");
    assert(spawnShell(distssh ~ " --export-env --env-file " ~ env_file,
            stdin, stdout, stderr, fake_env).wait == 0, "failed to export env");
    auto res = executeShell(format(distssh ~ " -i %s --local-run -- bash " ~ script_file, env_file));

    // assert
    assert(res.status == 0, "failed executing: " ~ res.output);
    assert(res.output.canFind("43"), "specified env file not imported");
}

@("shall import the env from the specified file specified via DISTSSH_IMPORT_ENV")
unittest {
    // arrange
    auto area = TestArea(__FILE__, __LINE__);
    const script_file = preCondition(area);

    // action
    const env_file = buildPath(area, "myenv.export");
    auto fake_env = ["SMURF" : "43"];
    assert(spawnShell(distssh ~ " --export-env --env-file " ~ env_file,
            stdin, stdout, stderr, fake_env).wait == 0, "failed to export env");

    fake_env = ["DISTSSH_IMPORT_ENV" : env_file];
    auto res = executeShell(distssh ~ " --local-run -- bash " ~ script_file, fake_env);

    // assert
    assert(res.status == 0, "failed executing: " ~ res.output);
    assert(res.output.canFind("43"), "specified env file not imported");
}
