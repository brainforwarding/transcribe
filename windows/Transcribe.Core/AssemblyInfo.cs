using System.Runtime.CompilerServices;

// Expose Core internals (e.g. Transcriber.BuildForm — the hand-built multipart, kept internal so
// it isn't part of the public surface) to the test assembly. This is the idiomatic .NET way to
// let unit tests assert on internal implementation details without making them public.
[assembly: InternalsVisibleTo("Transcribe.Tests")]
