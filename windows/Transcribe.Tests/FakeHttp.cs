using System.Net;
using System.Text;

namespace Transcribe.Tests;

/// <summary>
/// A scripted HttpMessageHandler: it buffers and records each request, then hands the request
/// (and its already-read body) to a responder that returns a canned response. Buffering means
/// the body is read exactly once here and is also re-readable by the responder if needed, so
/// multipart content (which is not re-readable by default) never trips us up.
/// </summary>
public sealed class FakeHttpHandler : HttpMessageHandler
{
    private readonly Func<HttpRequestMessage, string, Task<HttpResponseMessage>> _responder;
    public readonly List<HttpRequestMessage> Requests = new();
    public readonly List<string> RequestBodies = new();

    /// <summary>Responder that only cares about the request.</summary>
    public FakeHttpHandler(Func<HttpRequestMessage, Task<HttpResponseMessage>> responder)
        : this((req, _) => responder(req))
    {
    }

    /// <summary>Responder that also receives the pre-read request body string.</summary>
    public FakeHttpHandler(Func<HttpRequestMessage, string, Task<HttpResponseMessage>> responder)
    {
        _responder = responder;
    }

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Requests.Add(request);
        var body = "";
        if (request.Content != null)
        {
            // Buffer so the content can be read again by the responder if it wants to.
            await request.Content.LoadIntoBufferAsync();
            body = await request.Content.ReadAsStringAsync(cancellationToken);
        }
        RequestBodies.Add(body);
        return await _responder(request, body);
    }

    public static HttpResponseMessage Json(HttpStatusCode code, string body) =>
        new(code) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
}
