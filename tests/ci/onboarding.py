#!/usr/bin/env python3
"""No-OCI regression tests for the interactive Make workflow and saved plans."""
import base64
import os
import pathlib
import pty
import subprocess
import tempfile

LIB = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    for subdir in ("config", "stacks/bootstrap", "stacks/cluster", "bin"):
        (root / subdir).mkdir(parents=True)
    for stack in ("bootstrap", "cluster"):
        for shared in ("encryption", "locals", "providers", "variables", "versions"):
            (root / f"stacks/{stack}/_{shared}.tf").symlink_to(f"../../shared/{shared}.tf")
    (root / "shared").mkdir()
    for shared in ("encryption", "locals", "providers", "variables", "versions"):
        (root / f"shared/{shared}.tf").touch()
    (root / ".opentofu-version").write_text("1.13.1\n")
    shell_line = (LIB / "templates/consumer/Makefile").read_text().splitlines()[3]
    assert shell_line.startswith("SHELL")
    (root / "Makefile").write_text(f"{shell_line}\nLIB := {LIB}\ninclude {LIB}/make/consumer.mk\n")
    (root / "config/settings.tfvars.example").write_text(
        (LIB / "templates/consumer/config/settings.tfvars.example").read_text().replace(
            "UPSTREAM_REF", "main").replace("UPSTREAM_OWNER", "fake").replace("UPSTREAM_REPO", "fake")
    )
    token_file = root / "token"
    claims = base64.urlsafe_b64encode(b'{"sub":"ocid1.user.admin-fixture"}').decode().rstrip("=")
    token_file.write_text(f"fixture.{claims}.fixture")
    (root / "oci.conf").write_text(f"[root-profile]\ntenancy=ocid1.tenancy.fixture\nsecurity_token_file={token_file}\n")
    fake = root / "bin/fake"
    fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
cli, *args = sys.argv
name = pathlib.Path(cli).name
case = os.environ.get('TEST_CASE', '')
def log(value):
    with open('calls', 'a') as file:
        print(value, file=file)
def jsonout(value):
    print(json.dumps(value))
if name == 'oci':
    assert args[args.index('--auth') + 1] == 'security_token'
    if args[:3] != ['iam', 'region-subscription', 'list'] or '--region' in args:
        assert args[args.index('--region') + 1] == 'uk-london-1'
    cmd = ' '.join(args[:3])
    if cmd == 'os ns get': print('other' if case == 'wrong-ns' else 'fixture')
    elif cmd == 'iam region-subscription list': print('uk-london-1')
    elif cmd == 'os bucket get':
        if case == 'resume':
            jsonout({'data':{'compartment-id':'ocid1.tenancy.fixture','public-access-type':'NoPublicAccess','versioning':'Enabled'}})
        else:
            print('ServiceError:', file=sys.stderr)
            print(json.dumps({'status':404 if case != 'forbidden' else 403,'code':'BucketNotFound' if case != 'forbidden' else 'NotAuthorizedOrNotFound'}), file=sys.stderr)
            sys.exit(1)
    elif cmd == 'os bucket create': log('seed')
    elif cmd == 'os object list-object-versions': jsonout({'data':{'items':[]}})
    elif cmd == 'iam group list': jsonout([{'id':'ocid1.group.fixture'}])
    elif cmd == 'iam user list': jsonout([{'id':'ocid1.user.fixture','description':'Previously added'}])
    elif cmd == 'iam user list-groups':
        jsonout([{'id':'ocid1.group.admin' if case == 'extra-group' else 'ocid1.group.fixture'}])
    elif cmd == 'iam customer-secret-key list': pass
    elif cmd == 'iam customer-secret-key create':
        user = args[args.index('--user-id') + 1]
        assert user in ('ocid1.user.admin-fixture', 'ocid1.user.fixture')
        log('temp-key' if user == 'ocid1.user.admin-fixture' else 'key')
        jsonout({'data':{'id':'new-access','key':'new-secret'}})
    elif cmd == 'iam customer-secret-key delete': log('revoke-new')
    elif cmd == 'ce cluster create-kubeconfig':
        assert '--with-auth-context' in args
        log('kubeconfig')
    else: sys.exit('unexpected OCI command: ' + cmd)
elif name == 'gh':
    dest = pathlib.Path(args[args.index('-D') + 1]); dest.mkdir(parents=True)
    (dest / 'module_ref').write_text(''); (dest / 'tfplan').write_text(f'CI plan {args[2]}')
else:
    if args[0] == 'version': jsonout({'terraform_version':'1.13.1'}); sys.exit(0)
    if args[0] == 'fmt': sys.exit(0)
    cmd = args[1]
    stack = pathlib.Path(args[0].split('=', 1)[1])
    if cmd == 'init':
        assert all(flag not in args for flag in ('-upgrade', '-migrate-state', '-reconfigure'))
        if case == 'bad-init': sys.exit(1)
        (stack / '.initialized').touch()
    elif cmd == 'plan':
        plan = pathlib.Path(next(x[5:] for x in args if x.startswith('-out=')))
        plan.write_text('new plan'); log('plan')
        if case == 'bad-plan': sys.exit(1)
    elif cmd == 'show' and '-json' in args:
        config = {} if case == 'no-access' else {'api_allowed_cidrs':['192.0.2.1/32']}
        jsonout({'variables':{'cluster':{'value':config}}, 'resource_changes':[{'type':'oci_containerengine_cluster','change':{'actions':['create']}}]})
    elif cmd == 'show':
        log('show-ci' if args[-1].endswith('/.ci/review/tfplan') else 'show-bootstrap')
    elif cmd == 'apply':
        p = pathlib.Path(args[0].split('=', 1)[1]) / args[-1]
        assert p.read_text() == 'new plan'; log('apply')
    elif cmd == 'output':
        assert (stack / '.initialized').is_file(), 'state read without initialization'
        if os.environ.get('AWS_ACCESS_KEY_ID') == 'new-access' and case == 'bad-key': sys.exit(1)
        print({'state_access_group': 'oke-free-tofu-state', 'cluster_id': 'ocid1.cluster.fixture',
               'kubeconfig_command': 'oci --kube-endpoint PUBLIC_ENDPOINT --file fixture'}[args[-1]])
    else: sys.exit('unexpected tofu command: ' + cmd)
''')
    fake.chmod(0o755)
    for name in ("oci", "tofu", "gh"):
        (root / "bin" / name).symlink_to(fake)
    (root / "bin/sleep").write_text("#!/bin/sh\nexit 0\n")
    (root / "bin/sleep").chmod(0o755)
    shell_stub = root / "bin/state-shell"
    shell_stub.write_text('#!/bin/sh\n[ "$1" = -i ] && [ "$OCI_CLI_AUTH" = security_token ] && echo session >> calls\n')
    shell_stub.chmod(0o755)
    env = dict(os.environ, CI="false", PATH=f"{root}/bin:{os.environ['PATH']}",
               OCI_CLI_CONFIG_FILE=str(root / "oci.conf"), TF_VAR_state_passphrase="fixture-passphrase-long",
               AWS_ACCESS_KEY_ID="fixture", AWS_SECRET_ACCESS_KEY="fixture",
               OCI_PROFILE="root-profile", ALERT_EMAIL="alert@example.test", API_ALLOWED_CIDR="192.0.2.1/32")
    for var in ("OCI_CLI_AUTH", "MAKEFLAGS", "MFLAGS", "CONSUMER_MAKE"):
        env.pop(var, None)

    def run(*args, case="", answers=None, success=True):
        (root / "calls").write_text("")
        child_env = dict(env, TEST_CASE=case, OKE_SHELL=str(shell_stub))
        if case == "no-key":
            del child_env["AWS_ACCESS_KEY_ID"], child_env["AWS_SECRET_ACCESS_KEY"]
        if case == "short-passphrase":
            child_env["TF_VAR_state_passphrase"] = "short"
        if answers is None:
            result = subprocess.run(args, cwd=root, env=child_env, capture_output=True, timeout=20, stdin=subprocess.DEVNULL)
            output = result.stdout + result.stderr
        else:
            master, slave = pty.openpty()
            try:
                os.write(master, answers.encode())
                result = subprocess.run(args, cwd=root, env=child_env, stdin=slave, stdout=slave, stderr=slave, timeout=20)
            finally:
                os.close(slave)
            chunks = []
            try:
                while chunk := os.read(master, 4096):
                    chunks.append(chunk)
            except OSError:
                pass
            finally:
                os.close(master)
            output = b"".join(chunks)
        assert (result.returncode == 0) == success, output.decode(errors="replace")
        return (root / "calls").read_text().splitlines()

    assert run("make", "bootstrap-plan", answers="y\n") == ["seed", "plan"]
    settings = (root / "config/settings.tfvars").read_text()
    assert 'oci_auth        = "SecurityToken"' in settings and '["192.0.2.1/32"]' in settings
    bootstrap = root / "stacks/bootstrap"
    boot_plan = bootstrap / "tfplan"
    assert run("make", "-n", "bootstrap-apply", "state-credentials", answers="y\ny\ny\n") == []
    assert run("make", "-n", "bootstrap-plan", answers="y\n") == []
    assert boot_plan.read_text() == "new plan"
    assert run("make", "bootstrap-plan", case="short-passphrase", success=False) == []
    assert not boot_plan.exists()
    assert run("make", "bootstrap-apply", success=False) == []
    assert run("make", "bootstrap-plan", case="no-key", answers="y\ny\n") == ["seed", "temp-key", "plan"]
    assert run("make", "bootstrap-plan", case="no-key", answers="y\nn\nexisting-access\nexisting-secret\n") == ["seed", "plan"]
    assert run("make", "bootstrap-apply", answers="n\n", success=False) == ["show-bootstrap"]
    assert run("make", "bootstrap-apply", answers="y\nn\n") == ["show-bootstrap", "apply"]
    assert not boot_plan.exists()
    (bootstrap / ".initialized").unlink()
    assert run("make", "state-credentials", answers="y\ny\nnew-access\nnew-secret\n") == ["key"]
    (bootstrap / ".initialized").unlink()
    assert run("make", "session", answers="\n") == ["session"]
    assert run("make", "kubeconfig") == ["kubeconfig"]
    assert run("make", "state-credentials", answers="y\ny\n", case="extra-group", success=False) == []
    assert run("make", "state-credentials", answers="y\ny\n", case="bad-key", success=False) == ["key", "revoke-new"]
    assert run("make", "seed", case="forbidden", success=False) == []
    assert run("make", "seed", case="wrong-ns", success=False) == []
    assert run("make", "seed", case="resume", answers="y\n") == []

    local_plan = root / "stacks/cluster/tfplan"
    local_plan.write_text("stale plan")
    assert run("make", "-j2", "up", "apply-cluster", success=False) == []
    assert run("make", "-j2", "up") == ["plan"] and local_plan.read_text() == "new plan"
    assert run("make", "review-plan", "RUN=123") == ["show-ci"] and local_plan.read_text() == "new plan"
    assert run("make", "-n", "review-plan", "RUN=456") == []
    assert (root / ".ci/review/tfplan").read_text() == "CI plan 123" and local_plan.read_text() == "new plan"
    assert run("make", "plan-cluster", case="bad-init", success=False) == [] and not local_plan.exists()
    assert run("make", "plan-cluster", case="bad-plan", success=False) == ["plan"] and not local_plan.exists()
    assert run("make", "plan-cluster", case="no-access", success=False) == ["plan"] and not local_plan.exists()
    assert not (root / "stacks/cluster/pending.tfplan").exists()
print("onboarding fixture: configure, approval, resume, credential handoff/recovery, and plan isolation passed")
