const STICKY_MARKER = '<!-- rock-test-environment-status -->';

const STATE_LABELS = [
  'rock:queued',
  'rock:building',
  'rock:deploying',
  'rock:deployed',
  'rock:failed',
  'rock:stopped'
];

const STATUS_TO_LABEL = {
  queued: 'rock:queued',
  building: 'rock:building',
  deploying: 'rock:deploying',
  deployed: 'rock:deployed',
  failed: 'rock:failed',
  stopped: 'rock:stopped',
  destroyed: null
};

async function reconcilePrTestLabels({ github, owner, repo, issue_number, status }) {
  for (const label of STATE_LABELS) {
    try {
      await github.rest.issues.removeLabel({ owner, repo, issue_number, name: label });
    } catch (error) {
      if (error.status !== 404) {
        throw error;
      }
    }
  }

  const nextLabel = STATUS_TO_LABEL[status];
  if (nextLabel) {
    await github.rest.issues.addLabels({ owner, repo, issue_number, labels: [nextLabel] });
  }
}

function renderPrTestStatusComment({ status, hostName, sha, artifactGcsPath, logsUrl, updatedAt }) {
  const url = hostName ? `https://${hostName}` : '_Not available_';
  const deployedSha = sha ? `\`${sha}\`` : '_Not available_';
  const artifact = artifactGcsPath ? `\`${artifactGcsPath}\`` : '_Not available_';
  const logs = logsUrl ? `[GitHub Actions run](${logsUrl})` : '_Not available_';

  return `${STICKY_MARKER}
## PR Test Environment

| Field | Value |
| --- | --- |
| Status | **${status}** |
| URL | ${url} |
| Deployed SHA | ${deployedSha} |
| Artifact | ${artifact} |
| Last updated | ${updatedAt} |
| Logs | ${logs} |

### Commands

Apply one of these labels to manage the environment:

- \`rock:start\` — build and deploy the latest PR head.
- \`rock:stop\` — stop the IIS site/app pool but keep files and state.
- \`rock:destroy\` — remove IIS resources, files, and PR environment state.
- \`rock:auto\` — opt into redeploying automatically on PR pushes.

### Access and data notes

This URL is reachable from anywhere — no VPN needed. Port 443 on the test VM is open to the public internet (firewall rule \`https-from-world\`); the office-egress restriction applies only to RDP and SQL.

The first request after a deploy is slow, sometimes minutes: Rock applies its EF and plugin migrations at startup. Reload once before concluding anything is broken.

This environment uses a shared sandbox database and shared sandbox file storage, so it isolates code and runtime, **not data**. Every PR environment points at the same catalog, so treat the data as disposable and shared and don't rely on it to prove anything about a data change. Staging is the exception — it has its own catalog, so a data change you make here will not show up there.

**That catalog is a straight copy of production, not a sanitized one.** Real names, addresses and giving history, on a public URL behind nothing but Rock's login. Treat what you see here as live congregant data: don't paste screenshots into tickets and don't share the URL outside the team.
`;
}

async function findStickyComment({ github, owner, repo, issue_number }) {
  const comments = await github.paginate(github.rest.issues.listComments, {
    owner,
    repo,
    issue_number,
    per_page: 100
  });

  return comments.find(comment => comment.body && comment.body.includes(STICKY_MARKER));
}

async function updateStickyComment({ github, owner, repo, issue_number, body }) {
  const existing = await findStickyComment({ github, owner, repo, issue_number });
  if (existing) {
    await github.rest.issues.updateComment({ owner, repo, comment_id: existing.id, body });
  } else {
    await github.rest.issues.createComment({ owner, repo, issue_number, body });
  }
}

async function updatePrTestStatus({ github, context, owner, repo, prNumber, status, hostName, sha, artifactGcsPath, logsUrl }) {
  const issue_number = Number(prNumber);
  const updatedAt = new Date().toISOString();

  await reconcilePrTestLabels({ github, owner, repo, issue_number, status });
  await updateStickyComment({
    github,
    owner,
    repo,
    issue_number,
    body: renderPrTestStatusComment({ status, hostName, sha, artifactGcsPath, logsUrl, updatedAt })
  });
}

module.exports = {
  STATE_LABELS,
  STICKY_MARKER,
  reconcilePrTestLabels,
  renderPrTestStatusComment,
  updatePrTestStatus
};
