// The release workflow rewrites __KAGETE_VERSION__ with the pushed git tag
// (see .github/workflows/release.yml). Local dev builds show the literal
// placeholder so it's obvious the binary wasn't built from a release.
let kageteVersion = "__KAGETE_VERSION__"
