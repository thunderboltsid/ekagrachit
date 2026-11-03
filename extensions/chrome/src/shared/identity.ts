/**
 * Resource identity policy.
 *
 * A focus target is a *resource*, not a byte-for-byte URL. This module turns a
 * user-supplied URL into a deterministic `Identity` and answers, for any later
 * URL, whether it refers to the same resource.
 *
 * Design rules (see docs/architecture.md, "URL identity"):
 *  - Known resource types (Google Docs/Drive files, GitHub PRs/issues, Jira
 *    issues) are recognised explicitly by their stable identifier.
 *  - Everything else is an exact *page*: same scheme family, host, port and
 *    path (trailing slash insensitive), same query parameters (order
 *    insensitive, common tracking parameters ignored). Fragments are always
 *    ignored. No domain-wide wildcards, ever.
 *  - URLs with embedded credentials are rejected.
 *  - Percent-encoding variants are treated as distinct (conservative, and
 *    consistent with the declarativeNetRequest regexes generated below).
 *
 * This module is pure: no chrome.* APIs, no globals. It is unit tested in
 * tests/unit/identity.test.ts.
 */

export type Identity =
  | { kind: 'google'; docId: string; published: boolean; label: string }
  | { kind: 'github'; owner: string; repo: string; section: 'pull' | 'discussions'; number: string }
  | { kind: 'jira'; host: string; issueKey: string }
  | { kind: 'service'; service: ServiceName; host: string; id: string }
  | { kind: 'page'; allowHttp: boolean; host: string; port: string; path: string; query: string };

export type Verdict = 'allow' | 'auth' | 'neutral' | 'deny';

export interface FocusPolicy {
  primary: Identity;
  /** Extra exact-page identities learned from redirects during the landing grace period. */
  aliases: Identity[];
}

export type ParseResult =
  | { ok: true; identity: Identity; url: string }
  | { ok: false; error: string };

const GOOGLE_DOC_SERVICES = 'document|spreadsheets|presentation|forms|drawings';
const GOOGLE_DOCS_PATH = new RegExp(
  `^/(?:a/[^/]+/)?(${GOOGLE_DOC_SERVICES})/(?:u/\\d+/)?d/(e/)?([A-Za-z0-9_-]+)(?:[/].*)?$`,
);
const DRIVE_FILE_PATH = /^\/(?:u\/\d+\/)?file\/d\/([A-Za-z0-9_-]+)(?:\/.*)?$/;
const GITHUB_PATH = /^\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/(pull|issues|discussions)\/(\d+)(?:\/.*)?$/;
const JIRA_PATH = /^\/browse\/([A-Z][A-Z0-9_]*-\d+)(?:\/.*)?$/;

const TRACKING_PARAMS = new Set(['fbclid', 'gclid', 'dclid', 'msclkid', 'mc_cid', 'mc_eid', 'igshid']);

const SERVICE_LABELS: Record<string, string> = {
  document: 'Google Doc',
  spreadsheets: 'Google Sheet',
  presentation: 'Google Slides',
  forms: 'Google Form',
  drawings: 'Google Drawing',
  file: 'Google Drive file',
};

// ---------------------------------------------------------------------------
// Web apps recognised by a stable resource id. Each entry says how to read the
// id from a URL, which top-level URLs belong to the same resource (DNR allow
// patterns, a superset the matcher then narrows), and the sign-in pages the
// resource may bounce through.
// ---------------------------------------------------------------------------

export type ServiceName =
  | 'notion' | 'figma' | 'linear' | 'confluence' | 'gitlab' | 'bitbucket' | 'miro' | 'overleaf' | 'colab' | 'm365';

interface ServiceDef {
  label: string;
  /** Resource id (and canonical host) for a URL of this service, or null. */
  match(url: URL, host: string): { host: string; id: string } | null;
  allow(host: string, id: string): AllowPattern[];
  isAuth(url: URL, host: string, resourceHost: string): boolean;
  authPatterns(resourceHost: string): AllowPattern[];
}

const GOOGLE_AUTH: AllowPattern = { regex: '^https://accounts\\.google\\.com/.*', caseSensitive: false };
const MS_AUTH: AllowPattern = { regex: '^https://login\\.(microsoftonline\\.com|live\\.com)/.*', caseSensitive: false };
const ATLASSIAN_AUTH: AllowPattern = { regex: '^https://(id|auth)\\.atlassian\\.com/.*', caseSensitive: false };
const isGoogleAuth = (h: string) => h === 'accounts.google.com';
const isAtlassianAuth = (h: string) => h === 'id.atlassian.com' || h === 'auth.atlassian.com';
const TAIL = '([/?#].*)?$';

const SERVICES: Record<ServiceName, ServiceDef> = {
  notion: {
    label: 'Notion page',
    match(url, host) {
      const notion = host === 'notion.so' || host === 'www.notion.so';
      if (!notion && !host.endsWith('.notion.site')) return null;
      // …/Page-Title-<32 hex> or …/<uuid with dashes>: the id is the last 32 hex digits.
      const last = url.pathname.split('/').filter(Boolean).pop() ?? '';
      const id = /([0-9a-f]{32})$/i.exec(last.replace(/-/g, ''))?.[1]?.toLowerCase();
      return id ? { host: notion ? 'notion.so' : host, id } : null;
    },
    allow: (host, id) => {
      // Either the bare 32-digit form or the dashed UUID form.
      const uuid = [id.slice(0, 8), id.slice(8, 12), id.slice(12, 16), id.slice(16, 20), id.slice(20)].join('-?');
      const origin = host === 'notion.so' ? '(www\\.)?notion\\.so' : escapeRegex(host);
      return [{ regex: `^https://${origin}/(.*[-/])?${uuid}${TAIL}`, caseSensitive: false }];
    },
    isAuth: (url, host) => isGoogleAuth(host) || ((host === 'notion.so' || host === 'www.notion.so') && /^\/(login|loginwithemail|signup)/.test(url.pathname)),
    authPatterns: () => [GOOGLE_AUTH, { regex: '^https://(www\\.)?notion\\.so/(login|loginwithemail|signup)([/?#].*)?$', caseSensitive: false }],
  },
  figma: {
    label: 'Figma file',
    match(url, host) {
      if (host !== 'figma.com' && host !== 'www.figma.com') return null;
      const m = /^\/(?:file|design|board|proto|slides|deck|jam)\/([A-Za-z0-9]{10,})(?:\/.*)?$/.exec(url.pathname);
      return m ? { host: 'figma.com', id: m[1]! } : null;
    },
    allow: (_h, id) => [{ regex: `^https://(www\\.)?figma\\.com/(file|design|board|proto|slides|deck|jam)/${id}${TAIL}`, caseSensitive: true }],
    isAuth: (url, host) => isGoogleAuth(host) || ((host === 'figma.com' || host === 'www.figma.com') && url.pathname.startsWith('/login')),
    authPatterns: () => [GOOGLE_AUTH, { regex: '^https://(www\\.)?figma\\.com/login([/?#].*)?$', caseSensitive: false }],
  },
  linear: {
    label: 'Linear issue',
    match(url, host) {
      if (host !== 'linear.app') return null;
      const m = /^\/([^/]+)\/issue\/([A-Za-z][A-Za-z0-9]*-\d+)(?:\/.*)?$/.exec(url.pathname);
      return m ? { host, id: `${m[1]!.toLowerCase()}/${m[2]!.toUpperCase()}` } : null;
    },
    allow: (_h, id) => {
      const [ws, key] = id.split('/');
      return [{ regex: `^https://linear\\.app/${escapeRegex(ws!)}/issue/${escapeRegex(key!)}${TAIL}`, caseSensitive: false }];
    },
    isAuth: (url, host) => isGoogleAuth(host) || (host === 'linear.app' && url.pathname.startsWith('/login')),
    authPatterns: () => [GOOGLE_AUTH, { regex: '^https://linear\\.app/login([/?#].*)?$', caseSensitive: false }],
  },
  confluence: {
    label: 'Confluence page',
    match(url, host) {
      if (!host.endsWith('.atlassian.net')) return null;
      const m = /^\/wiki\/spaces\/[^/]+\/pages\/(\d+)(?:\/.*)?$/.exec(url.pathname);
      if (m) return { host, id: m[1]! };
      if (url.pathname === '/wiki/pages/viewpage.action') {
        const id = url.searchParams.get('pageId');
        return id && /^\d+$/.test(id) ? { host, id } : null;
      }
      return null;
    },
    allow: (host, id) => [
      { regex: `^https://${escapeRegex(host)}/wiki/spaces/[^/]+/pages/${id}${TAIL}`, caseSensitive: true },
      { regex: `^https://${escapeRegex(host)}/wiki/pages/viewpage\\.action\\?(.*&)?pageId=${id}(&.*)?$`, caseSensitive: true },
    ],
    isAuth: (_u, host) => isAtlassianAuth(host),
    authPatterns: () => [ATLASSIAN_AUTH],
  },
  gitlab: {
    label: 'GitLab',
    match(url, host) {
      const m = /^\/(.+?)\/-\/(merge_requests|issues)\/(\d+)(?:\/.*)?$/.exec(url.pathname);
      return m ? { host, id: `${m[1]!.toLowerCase()}|${m[2]}|${m[3]}` } : null;
    },
    allow: (host, id) => {
      const [project, type, n] = id.split('|');
      return [{ regex: `^https://${escapeRegex(host)}/${escapeRegex(project!)}/-/${type}/${n}${TAIL}`, caseSensitive: false }];
    },
    isAuth: (url, host, resourceHost) => host === resourceHost && url.pathname.startsWith('/users/'),
    authPatterns: (h) => [{ regex: `^https://${escapeRegex(h)}/users/(sign_in|auth)([/?#].*)?$`, caseSensitive: false }],
  },
  bitbucket: {
    label: 'Bitbucket pull request',
    match(url, host) {
      if (host !== 'bitbucket.org') return null;
      const m = /^\/([^/]+)\/([^/]+)\/pull-requests\/(\d+)(?:\/.*)?$/.exec(url.pathname);
      return m ? { host, id: `${m[1]!.toLowerCase()}/${m[2]!.toLowerCase()}/${m[3]}` } : null;
    },
    allow: (_h, id) => {
      const [ws, repo, n] = id.split('/');
      return [{ regex: `^https://bitbucket\\.org/${escapeRegex(ws!)}/${escapeRegex(repo!)}/pull-requests/${n}${TAIL}`, caseSensitive: false }];
    },
    isAuth: (url, host) => isAtlassianAuth(host) || (host === 'bitbucket.org' && url.pathname.startsWith('/account/signin')),
    authPatterns: () => [ATLASSIAN_AUTH, { regex: '^https://bitbucket\\.org/account/signin([/?#].*)?$', caseSensitive: false }],
  },
  miro: {
    label: 'Miro board',
    match(url, host) {
      if (host !== 'miro.com') return null;
      const m = /^\/app\/board\/([^/]+)\/?$/.exec(url.pathname);
      return m ? { host, id: m[1]! } : null;
    },
    allow: (_h, id) => [{ regex: `^https://miro\\.com/app/board/${escapeRegex(id)}/?([?#].*)?$`, caseSensitive: true }],
    isAuth: (url, host) => isGoogleAuth(host) || (host === 'miro.com' && /^\/(login|sso)/.test(url.pathname)),
    authPatterns: () => [GOOGLE_AUTH, { regex: '^https://miro\\.com/(login|sso)([/?#].*)?$', caseSensitive: false }],
  },
  overleaf: {
    label: 'Overleaf project',
    match(url, host) {
      if (host !== 'www.overleaf.com' && host !== 'overleaf.com') return null;
      const m = /^\/project\/([0-9a-f]{24})(?:\/.*)?$/.exec(url.pathname);
      return m ? { host: 'www.overleaf.com', id: m[1]! } : null;
    },
    allow: (_h, id) => [{ regex: `^https://(www\\.)?overleaf\\.com/project/${id}${TAIL}`, caseSensitive: true }],
    isAuth: (url, host) => isGoogleAuth(host) || ((host === 'www.overleaf.com' || host === 'overleaf.com') && url.pathname.startsWith('/login')),
    authPatterns: () => [GOOGLE_AUTH, { regex: '^https://(www\\.)?overleaf\\.com/login([/?#].*)?$', caseSensitive: false }],
  },
  colab: {
    label: 'Colab notebook',
    match(url, host) {
      if (host !== 'colab.research.google.com') return null;
      const m = /^\/drive\/([A-Za-z0-9_-]+)\/?$/.exec(url.pathname);
      return m ? { host, id: m[1]! } : null;
    },
    allow: (_h, id) => [{ regex: `^https://colab\\.research\\.google\\.com/drive/${id}/?([?#].*)?$`, caseSensitive: true }],
    isAuth: (_u, host) => isGoogleAuth(host),
    authPatterns: () => [GOOGLE_AUTH],
  },
  m365: {
    label: 'Microsoft 365 document',
    match(url, host) {
      let raw: string | null = null;
      if (host.endsWith('.sharepoint.com')) raw = url.searchParams.get('sourcedoc');
      else if (host === 'onedrive.live.com') raw = url.searchParams.get('resid');
      const id = raw?.replace(/[{}]/g, '').toLowerCase();
      return id && /^[0-9a-z!-]{8,}$/.test(id) ? { host, id } : null;
    },
    allow: (host, id) => [{
      regex: `^https://${escapeRegex(host)}/.*[?&](sourcedoc|resid)=(%7b|\\{)?${escapeRegex(id).replace(/!/g, '(!|%21)')}`,
      caseSensitive: false,
    }],
    isAuth: (_u, host) => host === 'login.microsoftonline.com' || host === 'login.live.com',
    authPatterns: () => [MS_AUTH],
  },
};

/** Ordered: specific services first; gitlab (any host) last. */
const SERVICE_ORDER: ServiceName[] = ['notion', 'figma', 'linear', 'confluence', 'bitbucket', 'miro', 'overleaf', 'colab', 'm365', 'gitlab'];

function serviceIdentity(url: URL, host: string): Identity | null {
  if (url.protocol !== 'https:' || url.port !== '') return null;
  for (const name of SERVICE_ORDER) {
    const m = SERVICES[name].match(url, host);
    if (m) return { kind: 'service', service: name, host: m.host, id: m.id };
  }
  return null;
}

/** Parse a user-entered target. Adds https:// when the scheme is omitted. */
export function parseTarget(input: string): ParseResult {
  const trimmed = input.trim();
  if (trimmed.length === 0) return { ok: false, error: 'Enter a URL to focus on.' };
  if (trimmed.length > 4096) return { ok: false, error: 'URL is too long.' };
  const withScheme = /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(trimmed) ? trimmed : `https://${trimmed}`;
  const url = safeURL(withScheme);
  if (!url) return { ok: false, error: 'That does not look like a valid URL.' };
  if (url.protocol !== 'https:' && url.protocol !== 'http:') {
    return { ok: false, error: 'Only http and https pages can be focus targets.' };
  }
  if (url.username !== '' || url.password !== '') {
    return { ok: false, error: 'URLs containing credentials are not allowed.' };
  }
  if (url.hostname === '') return { ok: false, error: 'URL has no host.' };
  return { ok: true, identity: identityOf(url), url: url.href };
}

/** Identity of an already-validated http(s) URL. */
export function identityOf(url: URL): Identity {
  const host = normalizeHost(url.hostname);
  if (url.protocol === 'https:' && url.port === '') {
    const google = googleIdentity(host, url);
    if (google) return google;
    if (host === 'github.com') {
      const m = GITHUB_PATH.exec(url.pathname);
      if (m) {
        return {
          kind: 'github',
          owner: m[1]!.toLowerCase(),
          repo: m[2]!.toLowerCase(),
          section: m[3] === 'discussions' ? 'discussions' : 'pull',
          number: m[4]!,
        };
      }
    }
    if (host.endsWith('.atlassian.net')) {
      const m = JIRA_PATH.exec(url.pathname);
      if (m) return { kind: 'jira', host, issueKey: m[1]! };
    }
    const svc = serviceIdentity(url, host);
    if (svc) return svc;
  }
  return {
    kind: 'page',
    allowHttp: url.protocol === 'http:',
    host,
    port: url.port,
    path: normalizePath(url.pathname),
    query: normalizeQuery(url.search),
  };
}

function googleIdentity(host: string, url: URL): Identity | null {
  if (host === 'docs.google.com') {
    const m = GOOGLE_DOCS_PATH.exec(url.pathname);
    if (m) {
      return { kind: 'google', docId: m[3]!, published: m[2] !== undefined, label: SERVICE_LABELS[m[1]!] ?? 'Google file' };
    }
  }
  if (host === 'drive.google.com') {
    const m = DRIVE_FILE_PATH.exec(url.pathname);
    if (m) return { kind: 'google', docId: m[1]!, published: false, label: SERVICE_LABELS.file! };
  }
  return null;
}

/** Same-resource test for a single identity. */
export function sameResource(identity: Identity, rawUrl: string): boolean {
  const url = safeURL(rawUrl);
  if (!url || url.username !== '' || url.password !== '') return false;
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return false;
  const host = normalizeHost(url.hostname);
  switch (identity.kind) {
    case 'google': {
      if (url.protocol !== 'https:' || url.port !== '') return false;
      if (host === 'docs.google.com') {
        const m = GOOGLE_DOCS_PATH.exec(url.pathname);
        return m !== null && m[3] === identity.docId && (m[2] !== undefined) === identity.published;
      }
      if (host === 'drive.google.com' && !identity.published) {
        const m = DRIVE_FILE_PATH.exec(url.pathname);
        if (m) return m[1] === identity.docId;
        if (/^\/(?:u\/\d+\/)?open\/?$/.test(url.pathname)) {
          return url.searchParams.get('id') === identity.docId;
        }
      }
      return false;
    }
    case 'github': {
      if (url.protocol !== 'https:' || url.port !== '' || host !== 'github.com') return false;
      const m = GITHUB_PATH.exec(url.pathname);
      if (!m) return false;
      const section = m[3] === 'discussions' ? 'discussions' : 'pull';
      return (
        m[1]!.toLowerCase() === identity.owner &&
        m[2]!.toLowerCase() === identity.repo &&
        section === identity.section &&
        m[4] === identity.number
      );
    }
    case 'jira': {
      if (url.protocol !== 'https:' || url.port !== '' || host !== identity.host) return false;
      const m = JIRA_PATH.exec(url.pathname);
      return m !== null && m[1] === identity.issueKey;
    }
    case 'service': {
      const m = url.protocol === 'https:' && url.port === '' ? SERVICES[identity.service].match(url, host) : null;
      return m !== null && m.host === identity.host && m.id === identity.id;
    }
    case 'page': {
      if (url.protocol === 'http:' && !identity.allowHttp) return false;
      return (
        host === identity.host &&
        url.port === identity.port &&
        normalizePath(url.pathname) === identity.path &&
        normalizeQuery(url.search) === identity.query
      );
    }
  }
}

/** Authentication flows the target may legitimately bounce through. */
export function isAuthUrl(identity: Identity, rawUrl: string): boolean {
  const url = safeURL(rawUrl);
  if (!url || url.protocol !== 'https:' || url.username !== '' || url.password !== '') return false;
  const host = normalizeHost(url.hostname);
  switch (identity.kind) {
    case 'google':
      return host === 'accounts.google.com' || (host === 'accounts.youtube.com' && url.pathname.startsWith('/accounts/SetSID'));
    case 'github':
      return host === 'github.com' && /^\/(login|session|sessions)(\/.*)?$/.test(url.pathname);
    case 'jira':
      return host === 'id.atlassian.com' || host === 'auth.atlassian.com';
    case 'service':
      return SERVICES[identity.service].isAuth(url, host, identity.host);
    case 'page':
      return false;
  }
}

/** Decide what to do with a top-level URL in the focus tab. */
export function evaluate(policy: FocusPolicy, rawUrl: string): Verdict {
  if (rawUrl === 'about:blank' || rawUrl === '') return 'neutral';
  if (sameResource(policy.primary, rawUrl)) return 'allow';
  for (const alias of policy.aliases) if (sameResource(alias, rawUrl)) return 'allow';
  if (isAuthUrl(policy.primary, rawUrl)) return 'auth';
  return 'deny';
}

/** Short human-readable description, e.g. for UI. Never includes query strings. */
export function describe(identity: Identity): string {
  switch (identity.kind) {
    case 'google':
      return `${identity.label} ${identity.docId.slice(0, 8)}…`;
    case 'github':
      return `${identity.owner}/${identity.repo} #${identity.number}`;
    case 'jira':
      return `${identity.issueKey}`;
    case 'service':
      return describeService(identity.service, identity.id);
    case 'page':
      return `${identity.host}${identity.port ? `:${identity.port}` : ''}${identity.path}`;
  }
}

function describeService(service: ServiceName, id: string): string {
  const label = SERVICES[service].label;
  switch (service) {
    case 'linear':
      return id.split('/')[1]!;
    case 'gitlab': {
      const [project, type, n] = id.split('|');
      return `${project} ${type === 'issues' ? '#' : '!'}${n}`;
    }
    case 'bitbucket': {
      const [ws, repo, n] = id.split('/');
      return `${ws}/${repo} #${n}`;
    }
    default:
      return label;
  }
}

/** Whether redirects during landing may add exact-page aliases for this identity. */
export function acceptsLandingAliases(identity: Identity): boolean {
  return identity.kind === 'page';
}

// ---------------------------------------------------------------------------
// declarativeNetRequest regexes (RE2 syntax).
//
// Invariant: every URL matched by these regexes for the *primary* identity
// should also be considered same-resource by `sameResource` OR be filtered by
// the event-driven guard afterwards. The regexes may be looser than the
// matcher (the guard reverses anything the matcher denies), but they must never
// be *stricter* for URLs Google/GitHub/Jira generate in normal use, otherwise
// legitimate navigation would be blocked. Tested in identity.test.ts.
// ---------------------------------------------------------------------------

export interface AllowPattern {
  regex: string;
  caseSensitive: boolean;
}

export function allowPatterns(identity: Identity): AllowPattern[] {
  const tail = '([/?#].*)?$';
  switch (identity.kind) {
    case 'google': {
      const id = identity.docId; // [A-Za-z0-9_-] only, no escaping needed
      const pub = identity.published ? 'e/' : '';
      const patterns: AllowPattern[] = [
        {
          regex: `^https://docs\\.google\\.com/(a/[^/]+/)?(${GOOGLE_DOC_SERVICES})/(u/[0-9]+/)?d/${pub}${id}${tail}`,
          caseSensitive: true,
        },
      ];
      if (!identity.published) {
        patterns.push({ regex: `^https://drive\\.google\\.com/(u/[0-9]+/)?file/d/${id}${tail}`, caseSensitive: true });
        patterns.push({ regex: `^https://drive\\.google\\.com/(u/[0-9]+/)?open/?\\?(.*&)?id=${id}(&.*)?$`, caseSensitive: true });
      }
      return patterns;
    }
    case 'github': {
      const section = identity.section === 'discussions' ? 'discussions' : '(pull|issues)';
      return [
        {
          regex: `^https://github\\.com/${escapeRegex(identity.owner)}/${escapeRegex(identity.repo)}/${section}/${identity.number}${tail}`,
          caseSensitive: false,
        },
      ];
    }
    case 'jira':
      return [
        { regex: `^https://${escapeRegex(identity.host)}/browse/${escapeRegex(identity.issueKey)}${tail}`, caseSensitive: true },
      ];
    case 'service':
      return SERVICES[identity.service].allow(identity.host, identity.id);
    case 'page': {
      const scheme = identity.allowHttp ? 'https?' : 'https';
      const port = identity.port ? `:${identity.port}` : '';
      const path = identity.path === '/' ? '/?' : `${escapeRegex(identity.path)}/?`;
      return [
        {
          regex: `^${scheme}://${escapeRegex(identity.host)}${port}${path}(\\?[^#]*)?(#.*)?$`,
          caseSensitive: true,
        },
      ];
    }
  }
}

export function authPatterns(identity: Identity): AllowPattern[] {
  switch (identity.kind) {
    case 'google':
      return [
        { regex: '^https://accounts\\.google\\.com/.*', caseSensitive: false },
        { regex: '^https://accounts\\.youtube\\.com/accounts/SetSID.*', caseSensitive: false },
      ];
    case 'github':
      return [{ regex: '^https://github\\.com/(login|session|sessions)([/?#].*)?$', caseSensitive: false }];
    case 'jira':
      return [{ regex: '^https://(id|auth)\\.atlassian\\.com/.*', caseSensitive: false }];
    case 'service':
      return SERVICES[identity.service].authPatterns(identity.host);
    case 'page':
      return [];
  }
}

// ---------------------------------------------------------------------------

function safeURL(raw: string): URL | null {
  try {
    return new URL(raw);
  } catch {
    return null;
  }
}

function normalizeHost(hostname: string): string {
  // URL already lowercases and IDNA-encodes; drop a trailing root dot.
  return hostname.endsWith('.') ? hostname.slice(0, -1) : hostname;
}

function normalizePath(pathname: string): string {
  if (pathname === '' || pathname === '/') return '/';
  return pathname.endsWith('/') ? pathname.slice(0, -1) : pathname;
}

function normalizeQuery(search: string): string {
  if (search === '' || search === '?') return '';
  const params = new URLSearchParams(search);
  const pairs: [string, string][] = [];
  for (const [k, v] of params) {
    if (k.startsWith('utm_') || TRACKING_PARAMS.has(k)) continue;
    pairs.push([k, v]);
  }
  pairs.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0));
  return pairs.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&');
}

export function escapeRegex(s: string): string {
  return s.replace(/[\\^$.*+?()[\]{}|]/g, '\\$&');
}
