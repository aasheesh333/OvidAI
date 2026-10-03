package android.webkit

// Android's SDK stub constructor is package-private.
class ArtifactTestResourceError : WebResourceError() {
    override fun getErrorCode() = -2
    override fun getDescription() = "PRIVATE document and URL"
}
