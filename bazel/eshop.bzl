"""eShop's build conventions: the Bazel counterpart of Directory.Build.props."""

load("@bazel_net//dotnet:defs.bzl", "csharp_library", "mstest_test")

_COMMON = {
    "editorconfigs": ["//:.editorconfig"],
    "implicit_usings": True,
    "treat_warnings_as_errors": True,
}

def eshop_library(name, srcs = None, **kwargs):
    """A class library built the way Directory.Build.props builds eShop projects.

    The assembly (and NuGet package) name matches the directory, like the
    .csproj it replaces.
    """
    csharp_library(
        name = name,
        assembly_name = name,
        srcs = srcs if srcs != None else native.glob(["**/*.cs"], exclude = ["bin/**", "obj/**"]),
        visibility = ["//visibility:public"],
        **(_COMMON | kwargs)
    )

def eshop_test(name, srcs = None, **kwargs):
    """An MSTest project, like the ones using MSTest.Sdk."""
    mstest_test(
        name = name,
        srcs = srcs if srcs != None else native.glob(["**/*.cs"], exclude = ["bin/**", "obj/**"]),
        **(_COMMON | kwargs)
    )
