using System.Net;
using Transcribe.Core;
using Xunit;

namespace Transcribe.Tests;

public class VerifyAndSummaryTests
{
    private static readonly Uri ProxyBase =
        new("https://transcribe-proxy.quiet-bush-25b1.workers.dev/v1");

    private static Summarizer MakeSummarizer(
        Func<HttpRequestMessage, Task<HttpResponseMessage>> responder, out FakeHttpHandler handler)
    {
        handler = new FakeHttpHandler(responder);
        return new Summarizer(new HttpClient(handler));
    }

    // --- token verification: 401 = rejected, anything else = accepted, throw = unreachable ---
    [Fact]
    public async Task Verify_401_IsRejected()
    {
        var s = MakeSummarizer(_ =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.Unauthorized)), out _);
        Assert.Equal(Summarizer.VerifyResult.Rejected, await s.VerifyTokenAsync(ProxyBase, "bad"));
    }

    [Theory]
    [InlineData(HttpStatusCode.Forbidden)]       // recognized token, model not allowed
    [InlineData(HttpStatusCode.BadRequest)]
    [InlineData(HttpStatusCode.OK)]
    [InlineData(HttpStatusCode.NotFound)]
    public async Task Verify_NonAuthErrors_AreAccepted(HttpStatusCode code)
    {
        var s = MakeSummarizer(_ => Task.FromResult(new HttpResponseMessage(code)), out _);
        Assert.Equal(Summarizer.VerifyResult.Accepted, await s.VerifyTokenAsync(ProxyBase, "good"));
    }

    [Fact]
    public async Task Verify_NetworkFailure_IsUnreachable()
    {
        var s = MakeSummarizer(_ => throw new HttpRequestException("offline"), out _);
        Assert.Equal(Summarizer.VerifyResult.Unreachable, await s.VerifyTokenAsync(ProxyBase, "x"));
    }

    [Fact]
    public async Task Verify_SendsExactBodyAndAuthHeader()
    {
        var s = MakeSummarizer(_ =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.Forbidden)), out var handler);
        await s.VerifyTokenAsync(ProxyBase, "tok-123");

        var req = Assert.Single(handler.Requests);
        Assert.Equal(HttpMethod.Post, req.Method);
        Assert.EndsWith("/v1/chat/completions", req.RequestUri!.AbsoluteUri);
        Assert.Equal("Bearer tok-123", req.Headers.GetValues("Authorization").Single());
        Assert.Equal("{\"model\":\"__verify__\"}", handler.RequestBodies.Single());
    }

    // --- summary body shape ---
    [Fact]
    public void SummaryBody_UsesPromptPrefixAndModel()
    {
        var body = Summarizer.BuildSummaryBody("the conversation", "gpt-4o");
        Assert.Contains("\"model\":\"gpt-4o\"", body);
        Assert.Contains("Summarize this meeting transcript.", body);
        Assert.Contains("the conversation", body);
        Assert.Contains("\"role\":\"user\"", body);
    }

    [Fact]
    public async Task Summarize_ReturnsTrimmedContent()
    {
        var s = MakeSummarizer(_ => Task.FromResult(FakeHttpHandler.Json(HttpStatusCode.OK,
            "{\"choices\":[{\"message\":{\"content\":\"  hi  \"}}]}")), out _);
        Assert.Equal("hi", await s.SummarizeAsync(
            new OpenAIConfig(ProxyBase, "Bearer x"), "t"));
    }

    [Fact]
    public async Task Summarize_ReturnsNullOnError()
    {
        var s = MakeSummarizer(_ =>
            Task.FromResult(FakeHttpHandler.Json(HttpStatusCode.InternalServerError, "boom")), out _);
        Assert.Null(await s.SummarizeAsync(new OpenAIConfig(ProxyBase, "Bearer x"), "t"));
    }

    [Fact]
    public async Task Summarize_ReturnsNullOnEmptyContent()
    {
        var s = MakeSummarizer(_ => Task.FromResult(FakeHttpHandler.Json(HttpStatusCode.OK,
            "{\"choices\":[{\"message\":{\"content\":\"   \"}}]}")), out _);
        Assert.Null(await s.SummarizeAsync(new OpenAIConfig(ProxyBase, "Bearer x"), "t"));
    }

    // --- config seam ---
    [Fact]
    public void AppConfig_ProxyBaseUrl_MatchesSwiftConfig()
    {
        Assert.Equal("https://transcribe-proxy.quiet-bush-25b1.workers.dev/v1",
            AppConfig.ProxyBaseUrl!.AbsoluteUri);
        Assert.Equal(AppConfig.ProxyBaseUrl, AppConfig.ApiBaseUrl);
    }

    [Fact]
    public void OpenAIConfig_HasKey()
    {
        Assert.True(new OpenAIConfig(ProxyBase, "Bearer abc").HasKey);
        Assert.False(new OpenAIConfig(ProxyBase, "Bearer ").HasKey);
        Assert.False(new OpenAIConfig(ProxyBase, "").HasKey);
    }
}
