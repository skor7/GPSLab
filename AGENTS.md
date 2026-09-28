# GPSLab project instructions

After completing any requested coding task in this repository:

1. Finish all requested changes before touching Git.
2. Run the relevant validation/build/static checks available in this repository.
3. If any required check fails, DO NOT commit or push. Fix the failure first.
4. If checks pass and `git status --porcelain` shows changes:
   - run `git add -A`
   - create one concise commit describing the completed task
   - run `git push origin HEAD`
5. Never use force-push.
6. Never run reset --hard, clean -fd, rebase, or destructive Git commands.
7. Do not commit secrets, certificates, provisioning profiles, .p12 files, passwords, API keys, or signing material.
8. If there are no changes, do not create an empty commit.
9. If push fails, report the exact Git error instead of retrying destructively.
10. This auto commit/push policy applies only to this GPSLab repository.
