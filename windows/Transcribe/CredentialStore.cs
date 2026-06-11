using System.Runtime.InteropServices;
using System.Text;

namespace Transcribe.App;

/// <summary>
/// Token storage in the Windows Credential Manager (Generic credential), the Windows analog of
/// the macOS Keychain wrapper. Never a file, never registry plaintext — the SPEC requires the
/// credential vault. Stored under a stable target name; the secret is the team token / OpenAI key.
/// </summary>
public static class CredentialStore
{
    // Mirrors the macOS Keychain service/account → a single Generic credential target.
    private const string TargetName = "com.sebastianmarambio.transcribe:openai-api-key";

    private const int CRED_TYPE_GENERIC = 1;
    private const int CRED_PERSIST_LOCAL_MACHINE = 2;
    private const int ERROR_NOT_FOUND = 1168;

    [StructLayout(LayoutKind.Sequential)]
    private struct CREDENTIAL
    {
        public int Flags;
        public int Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredReadW(string target, int type, int reservedFlag, out IntPtr credentialPtr);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWriteW(ref CREDENTIAL credential, int flags);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDeleteW(string target, int type, int reservedFlag);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern void CredFree(IntPtr cred);

    /// <summary>Store (overwrite) the token. Empty/whitespace is ignored.</summary>
    public static void Set(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return;
        var blob = Encoding.Unicode.GetBytes(value);
        var blobPtr = Marshal.AllocHGlobal(blob.Length);
        var targetPtr = Marshal.StringToCoTaskMemUni(TargetName);
        var userPtr = Marshal.StringToCoTaskMemUni(Environment.UserName);
        try
        {
            Marshal.Copy(blob, 0, blobPtr, blob.Length);
            var cred = new CREDENTIAL
            {
                Type = CRED_TYPE_GENERIC,
                TargetName = targetPtr,
                CredentialBlobSize = blob.Length,
                CredentialBlob = blobPtr,
                Persist = CRED_PERSIST_LOCAL_MACHINE,
                UserName = userPtr,
            };
            if (!CredWriteW(ref cred, 0))
            {
                throw new InvalidOperationException(
                    $"CredWrite failed: {Marshal.GetLastWin32Error()}");
            }
        }
        finally
        {
            Marshal.FreeHGlobal(blobPtr);
            Marshal.FreeCoTaskMem(targetPtr);
            Marshal.FreeCoTaskMem(userPtr);
        }
    }

    /// <summary>Read the token, or null if not set.</summary>
    public static string? Get()
    {
        if (!CredReadW(TargetName, CRED_TYPE_GENERIC, 0, out var ptr))
        {
            return null;
        }
        try
        {
            var cred = Marshal.PtrToStructure<CREDENTIAL>(ptr);
            if (cred.CredentialBlobSize == 0 || cred.CredentialBlob == IntPtr.Zero) return null;
            var bytes = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, bytes, 0, cred.CredentialBlobSize);
            var s = Encoding.Unicode.GetString(bytes);
            return string.IsNullOrEmpty(s) ? null : s;
        }
        finally
        {
            CredFree(ptr);
        }
    }

    /// <summary>Remove the stored token (best-effort).</summary>
    public static void Clear()
    {
        if (!CredDeleteW(TargetName, CRED_TYPE_GENERIC, 0))
        {
            var err = Marshal.GetLastWin32Error();
            if (err != ERROR_NOT_FOUND)
            {
                // Non-fatal; nothing the user can do, swallow.
            }
        }
    }

    /// <summary>Last-4 fingerprint of the stored secret, or null. Mirrors keyFingerprint.</summary>
    public static string? Fingerprint()
    {
        var k = Get();
        if (k is null || k.Length < 4) return null;
        return k[^4..];
    }
}
