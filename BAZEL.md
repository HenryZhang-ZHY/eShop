# Building eShop with Bazel

This branch builds eShop's class libraries with [Bazel](https://bazel.build) through [bazel.net](../bazel.net), and leaves the application projects to the .NET SDK. The goal is faster builds and CI for large monorepos, not a replacement for MSBuild: Bazel owns the code that makes up most of a large monorepo, the shared class libraries, and the SDK keeps everything it does well for applications.

## Who builds what

| | Built by | Why |
|---|---|---|
| `src/EventBus`, `src/EventBusRabbitMQ`, `src/IntegrationEventLogEF`, `src/Ordering.Domain`, `src/Ordering.Infrastructure`, `src/eShop.ServiceDefaults` | Bazel (`BUILD.bazel`) | Plain class libraries: content-hashed incremental builds, shared cache, test selection |
| `tests/Ordering.Domain.UnitTests` | Bazel (MSTest on Microsoft.Testing.Platform) | Needs only the domain, so it reruns only when the domain changes |
| APIs, `WebApp`, `WebAppComponents` (Razor), workers, `eShop.AppHost` (Aspire), MAUI apps, and tests that start those hosts | .NET SDK (`.csproj`) | Web SDK, Razor, Aspire, publishing: Microsoft's machinery, used unchanged |

The two halves meet at **NuGet packages**. Bazel packs each library as `0.0.0-ws.<content hash>`, where the hash covers the assembly and its dependencies' versions. Host projects reference the libraries with ordinary, versionless `<PackageReference>`s. Central Package Management supplies the versions from a generated file, and `nuget.config` maps the library ids to a local feed only. Host projects don't know Bazel exists.

```
src/Ordering.Domain/BUILD.bazel ──bazel──▶ Ordering.Domain.0.0.0-ws.28348ef2….nupkg
                                                │  bazel run //:packages
                                                ▼
                         .bazel-packages/  (local feed + Workspace.Packages.props)
                                                │  NuGet restore
                                                ▼
                         src/Ordering.API/Ordering.API.csproj  (dotnet build)
```

Unchanged libraries keep their version, so restore stays a no-op for them.

## Everyday commands

Bazel downloads its own pinned .NET 10 SDK; nothing needs to be installed except [bazelisk](https://github.com/bazelbuild/bazelisk).

```bash
bazel build //...                 # build every Bazel-owned library
bazel test //...                  # run the Bazel-owned tests (only those affected by your change)
bazel run //:packages             # publish the libraries to .bazel-packages/ for the hosts
dotnet build eShop.Web.slnf       # build the hosts as before
```

After changing a library, run `bazel run //:packages` before building or running a host.

Other tasks:

- **Add a NuGet package to a library.** Add its `<PackageVersion>` to `Directory.Packages.props` if it isn't there yet, list it in `nuget_lock` in the root `BUILD.bazel`, run `bazel run //:nuget_lock`, then add `@nuget//:<PackageId>` to the library's `deps`.
- **Add a library.** Create `src/<Name>/BUILD.bazel` with `eshop_library` (see `bazel/eshop.bzl`, the counterpart of `Directory.Build.props`), add it to `workspace_packages` in the root `BUILD.bazel` if hosts use it, and map its id to the `workspace` source in `nuget.config`.
- **See what a change affects.** `bazel query "rdeps(//..., //src/EventBus)"`.

## Measured incrementality

Measured on a Windows laptop with the local disk cache from `.bazelrc`, by running `bazel test //...` after each step:

| Step | Time | Recompiled | Tests rerun |
|---|---|---|---|
| Clean build and test, empty caches | 26.0 s | everything | all |
| Nothing changed | 0.7 s | nothing | none |
| Edit a method body in `Ordering.Domain` | 3.3 s | `Ordering.Domain` only | domain tests |
| Add a public method to `Ordering.Domain` | 4.9 s | `Ordering.Domain`, `Ordering.Infrastructure`, domain tests | domain tests |
| Revert (as after switching branches) | 1.0 s | nothing (7 cache hits) | none |
| Edit a method body in `EventBus` (bottom of the graph) | 2.4 s | `EventBus` only | none (no test depends on it) |
| `bazel clean`, then build with a warm cache | 4.8 s | nothing (21 cache hits) | none |

Body-only edits stop at the edited library because dependents compile against reference assemblies, which don't change when only method bodies do. The last row is what a fresh CI runner gets from a shared remote cache.

## CI outline

Bazel decides what has to run, for its own targets and for the hosts:

```bash
bazel test //... --remote_cache=$CACHE_URL     # libraries + their tests; cached results are reused
bazel run //:packages                          # refresh the local feed
# A host is affected only if its sources or the workspace package versions changed:
fingerprint=$(cat .bazel-packages/Workspace.Packages.props $(git ls-files src/Ordering.API) | sha256sum)
# ...skip `dotnet build` / `dotnet test` for hosts whose fingerprint is cached.
dotnet build eShop.Web.slnf && dotnet test --project tests/Ordering.UnitTests
```

The workspace versions are content hashes, so the generated props file is an exact fingerprint of everything a host consumes from Bazel.

## Known gaps

- **IDE support for Bazel-owned libraries.** The six libraries no longer have `.csproj` files, so Visual Studio, Rider and the Roslyn language server don't load them. Host projects still work, and they see the libraries as packages. Generating project information for Roslyn from the Bazel graph is an open bazel.net problem.
- **AOT/trim analyzers.** `IsAotCompatible` pulls in ILLink analyzers through an SDK-implicit package. bazel.net doesn't add them yet, so Bazel builds of EventBus/EventBusRabbitMQ skip those warnings.
- **Debug symbols.** Libraries ship portable PDBs next to the DLL instead of `DebugType=embedded`.
- **Not migrated:** functional tests (they start hosts through Aspire and need Docker), `WebAppComponents` (a Razor class library, which needs the Razor SDK), and host-side unit tests that reference host projects.
- **bazel.net is unpublished.** `MODULE.bazel` points at a sibling checkout through `local_path_override`. CI needs that checkout, or a published module.
