// The Focus proxy's Netlify copy: RETIRED in v7.10.58 (Richard, 2026-11-22: "go with
// recommendations, start phase 1"; docs/microsoft/SCOPE.md, decision 11).
//
// Since v7.10.21 the proxy has run as a Supabase Edge Function (supabase/functions/sb),
// reached through the /sb/* rewrite in netlify.toml, and this function stayed deployed
// only as a rollback. From v7.10.58 the proxy guards sign-in: it keeps credentials where
// no request can reach them, asks for an Authenticator code, and refuses a write to the
// access tables that a login may not make. A second, older proxy on the same service key
// would be a way round every one of those, so this endpoint now answers 410 to
// everything. It is kept as a file so the address does not fall through to the site.
//
// The implementation as it last ran is in the repository's history:
//   git show ca745a0:netlify/functions/sb.js
// Do not restore it as it was. A rollback of the proxy now means redeploying an earlier
// version of the Edge Function.
exports.handler = async () => ({
  statusCode: 410,
  headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  body: JSON.stringify({ error: 'gone', message: 'This endpoint was retired in Focus v7.10.58. Focus uses /sb.' }),
});
