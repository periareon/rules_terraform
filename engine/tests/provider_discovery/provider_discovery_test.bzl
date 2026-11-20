"""Cold provider resolution discovers each registry once across providers and platforms."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//engine:provider_repo.bzl", "resolve_providers_from_lock_file")

_SHA = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"

def _lock(registry, names):
    return "\n".join([
        'provider "{}/example/{}" {{\n version = "1.0.0"\n hashes = [\n "zh:{}",\n ]\n}}'.format(registry, name, _SHA)
        for name in names
    ])

def _test_impl(ctx):
    env = unittest.begin(ctx)
    calls = []
    documents = {}
    locks = {
        "first": _lock("one.example", ["alpha", "beta"]),
        "second": _lock("one.example", ["gamma"]) + "\n" + _lock("two.example", ["delta"]),
    }

    def download(url, output, allow_fail = False):
        calls.append(url)
        if url.endswith("/.well-known/terraform.json"):
            payload = {"providers.v1": "/custom/providers/"}
        elif url.endswith("/versions"):
            payload = {"versions": [{
                "version": "1.0.0",
                "platforms": [{"os": "linux", "arch": arch} for arch in ["amd64", "arm64"]],
            }]}
        else:
            payload = {"download_url": url + ".zip", "shasum": _SHA}
        documents[output] = json.encode(payload)
        return struct(success = True)

    def read(path):
        return locks[path] if path in locks else documents[path]

    module_ctx = struct(download = download, read = read)
    services = {}
    pool = {}
    facts = {}
    for lock in locks:
        resolve_providers_from_lock_file(
            module_ctx,
            lock,
            pool,
            platforms = [("linux", "amd64"), ("linux", "arm64")],
            new_facts = facts,
            services = services,
        )
    discoveries = [url for url in calls if url.endswith("/.well-known/terraform.json")]
    asserts.equals(env, ["https://one.example/.well-known/terraform.json", "https://two.example/.well-known/terraform.json"], discoveries)
    asserts.equals(env, 8, len(pool))
    asserts.true(env, all([entry.sha256 == _SHA for entry in pool.values()]))
    asserts.true(env, all(["/custom/providers/" in entry.url for entry in pool.values()]))
    return unittest.end(env)

provider_discovery_test = unittest.make(_test_impl)
