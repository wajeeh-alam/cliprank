# Production deployment

The production plan uses a Render Blueprint for the Rails web process, Solid
Queue worker, private FastAPI service, and PostgreSQL. Uploaded source media and
rendered previews live in a private Cloudflare R2 bucket instead of an
instance-local filesystem.

No production resources have been created yet. Creating the Render services or
Cloudflare account/bucket can incur charges and requires the repository owner's
approval.

## Current cost check (October 31, 2026)

| Resource | Selected size | Monthly baseline |
| --- | --- | ---: |
| Render Rails web | 0.5 CPU, 512 MB | $7.00 |
| Render background worker | 0.5 CPU, 512 MB | $7.00 |
| Render private ML service | 1 CPU, 2 GB | $25.00 |
| Render Postgres | 0.1 CPU, 256 MB | $6.00 |
| Render Whisper cache disk | 1 GB | $0.25 |
| Cloudflare R2 | Within 10 GB / free request allowance | $0.00 |
| **Expected idle baseline** | | **$45.25/month** |

Usage above the included quotas is extra. R2 currently includes 10 GB-month of
standard storage, one million Class A operations, ten million Class B
operations, and free egress; beyond that, standard storage is $0.015/GB-month.
The application caps each upload at 250 MB and each allowlisted account at
three uploads per rolling 24 hours, which bounds demo usage but is not a
spending guarantee. Configure provider budget alerts before sharing the URL.

Sources checked on October 31, 2026:

- [Render pricing](https://render.com/pricing)
- [Render compute plans](https://render.com/docs/compute-plans)
- [Render Blueprint specification](https://render.com/docs/blueprint-spec)
- [Cloudflare R2 pricing](https://developers.cloudflare.com/r2/pricing/)

Railway would ordinarily be a lower-cost fit, but it is not the selected host:
new signups remain paused while Railway investigates its October 21, 2026
credential-exposure incident. See Railway's
[preliminary report](https://blog.railway.com/p/preliminary-report-october-security-incident)
and [current incident status](https://status.railway.com/incident/O1VGXWU5).
Fly.io was also evaluated, but its current managed Postgres baseline alone is
$38/month, before the application machines and object storage.

## Architecture

```text
Browser --HTTPS--> Rails web --private network--> PostgreSQL
   |                    |
   |                    +--> private R2 source media / previews
   |                    +--> Solid Queue rows
   |                                  |
   +--short-lived R2 URL<-- Rails <-- worker --private HTTP--> FastAPI/Whisper
```

Rails is the only public application service. It owns authentication,
authorization, durable workflow state, quotas, and presigned playback links.
The worker consumes Solid Queue records from the same managed database. The ML
service is private and requires a generated bearer token even on Render's
private network. Its attached disk caches public Whisper weights; it does not
store user media. R2 objects remain private and are reachable only through
short-lived signed URLs.

## Approval-gated deployment checklist

1. Approve the unpushed source diff and the $45.25/month baseline.
2. Create a private Cloudflare R2 bucket and an object-scoped API token. Do not
   use an account-wide token. Keep the bucket's public development URL off.
3. Connect the repository to Render and create the Blueprint from
   `render.yaml`. Supply these prompted values in the Render dashboard:

   - `S3_ENDPOINT`: the R2 S3 API endpoint, not a public bucket URL;
   - `S3_BUCKET`: the private bucket name;
   - `S3_ACCESS_KEY_ID` and `S3_SECRET_ACCESS_KEY`: the object-scoped token;
   - `UPLOAD_ALLOWED_EMAILS`: the resume-demo owner's normalized email;
   - `FEEDBACK_OPERATOR_EMAIL`: the same owner email, or a separate operator.

4. Leave `SIGNUPS_ENABLED=false` and `FEEDBACK_RANKING_ENABLED=true`. The
   feedback scorer records compatible shadow-model results, but shadow models
   cannot change the selected order. Activation remains explicit and blocked
   until real, time-valid outcome labels pass the documented release gates.
5. After the first healthy deploy, temporarily add `DEMO_OWNER_EMAIL` and
   `DEMO_OWNER_PASSWORD` as secret environment variables on the web service,
   open a Render shell, and run:

   ```sh
   bin/rails runner 'user = User.find_or_initialize_by(email: ENV.fetch("DEMO_OWNER_EMAIL").downcase); user.password = ENV.fetch("DEMO_OWNER_PASSWORD"); user.password_confirmation = user.password; user.save!'
   ```

   Remove both temporary variables immediately afterward. Never put the
   password in a command, repository file, deploy log, or screenshot.
6. Verify `/up`, sign-in rejection for an unknown account, and upload rejection
   for a signed-in non-allowlisted account before sharing the URL.
7. Upload one real video with the owner account. Confirm the database records a
   successful processing run, five ranked clips when the source supports five
   distinct candidates, ready preview artifacts, and playable browser media.
8. Only after that live verification, add the verified URL and screenshots to
   the README.

## Operational limitations

- The selected 512 MB web and worker plans are deliberately small. A complex
  FFmpeg input may exceed the worker's memory; upgrade the worker before raising
  the upload cap if Render reports an out-of-memory restart.
- The first transcription after creating or replacing the ML disk downloads
  the configured Whisper model and is slower than warm requests.
- One active pipeline per account and one worker process keep demo load bounded;
  this is not a high-throughput production topology.
- R2 storage is durable, but no cross-provider backup or retention policy is
  configured. The 1 GB Postgres plan also needs an explicit backup/export plan
  before storing irreplaceable data.
- Social publishing remains human-approved and internal in this MVP. Imported
  historical metrics are evidence, not forecasts of future reach.
