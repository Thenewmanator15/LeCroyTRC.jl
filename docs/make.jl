using Documenter, LeCroyTRC
using Base64: base64encode
using SHA: sha256

makedocs(;
    sitename = "LeCroyTRC.jl",
    modules = [LeCroyTRC],
    checkdocs = :exports,   # the internal helpers carry docstrings too
    pages = ["Home" => "index.md", "Reference" => "reference.md"],
)

# Content Security Policy. GitHub Pages cannot send response headers, so each page gets
# the policy as a <meta http-equiv> tag straight after <meta charset>. The one outside
# host is cdnjs: Documenter loads RequireJS, jQuery, highlight.js, KaTeX, Headroom and
# the search library (MiniSearch) from it, and the Lato, JuliaMono, Font Awesome and
# KaTeX style sheets and fonts. Inline <script> and <style> blocks are allowed by their
# SHA-256 hash, worked out per page, so neither 'unsafe-inline' nor 'unsafe-eval' is used.
const CSP_HOST = "https://cdnjs.cloudflare.com"

csp_hash(text) = "'sha256-$(base64encode(sha256(text)))'"
unescape(v) = replace(v, "&quot;" => "\"", "&#39;" => "'", "&lt;" => "<", "&gt;" => ">", "&amp;" => "&")

# Stop the build if a page or script loads from a host the policy does not list, rather
# than publish pages the browser would break. If Documenter really does use a new host,
# add it to the policy.
function check_hosts(where, hosts)
    for host in hosts
        host == CSP_HOST || error("$where loads from $host, which the CSP does not allow")
    end
end

function add_csp(build)
    # Style attributes that Documenter's own scripts write (the search results use one).
    # 'unsafe-hashes' lets a hash cover a style attribute: each exact value is allowed,
    # and any other style attribute stays blocked.
    js_styles = String[]
    for (dir, _, files) in walkdir(joinpath(build, "assets")), file in filter(endswith(".js"), files)
        js = read(joinpath(dir, file), String)
        append!(js_styles, m[2] for m in eachmatch(r"style=(\"|')([^\"'$]*)\1", js))
        check_hosts(file, (m[1] for m in eachmatch(r"[\"'](https?://[^/\"']+)/", js)))
    end
    pages = 0
    for (dir, _, files) in walkdir(build), file in filter(endswith(".html"), files)
        path = joinpath(dir, file)
        html = read(path, String)
        found(re) = unique(m[1] for m in eachmatch(re, html))
        tags = eachmatch(r"<[^>]*\ssrc=\"https?://[^>]*>|<link\b[^>]*\bstylesheet\b[^>]*>", html)
        check_hosts(path, (m[1] for t in tags for m in eachmatch(r"\s(?:src|href)=\"(https?://[^/\"]+)", t.match)))
        scripts = csp_hash.(found(r"<script(?![^>]*\ssrc=)[^>]*>(.*?)</script>"s))
        styles = csp_hash.(found(r"<style\b[^>]*>(.*?)</style>"s))
        attrs = unique([js_styles; unescape.(found(r"<[a-zA-Z][^>]*?\sstyle=\"([^\"]*)\""))])
        policy = join(filter(!isempty, [
            "default-src 'self'",
            join(["script-src 'self'", CSP_HOST, scripts...], " "),
            join(["style-src 'self'", CSP_HOST, styles...], " "),
            isempty(attrs) ? "" : join(["style-src-attr 'unsafe-hashes'", csp_hash.(attrs)...], " "),
            "font-src 'self' $CSP_HOST",
            "img-src 'self' data:",              # data: for images Documenter embeds in pages
            "connect-src 'self'",                # the version menu checks a page exists first
            "worker-src blob:",                  # the search index runs in a worker made from a blob
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
        ]), "; ")
        charset = match(r"<meta charset=\"[^\"]*\"/?>", html)
        charset === nothing && error("$path has no <meta charset> to put the CSP after")
        meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"$policy\"/>"
        write(path, replace(html, charset.match => charset.match * meta; count = 1))
        pages += 1
    end
    @info "Content Security Policy added to $pages pages."
end

add_csp(joinpath(@__DIR__, "build"))

deploydocs(; repo = "github.com/Thenewmanator15/LeCroyTRC.jl.git", devbranch = "main")
