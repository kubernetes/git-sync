# Authenticating against GitHub as an App

## Why it's a good idea

- GitHub deprecated the option to authenticate against it's API using username and password
- GitHub Apps have a way higher API limit than personal access tokens (up to around 15000 requests per hour)
- GitHub Apps can be limited to specific repositories with very granular permission scopes
- Useful in organizations, where using a personal access token or a bot user is discouraged or not alld
    - GitHub App Installations shouldn't be affected by an employee leaving the company for example
    
## How To

1. Create a new GitHub App: `https://github.com/organizations/<org>/settings/apps/new` with all the required permissions (read-access on repo: content)
2. Install the App to your organization with access to the target repositories
3. Generate the private key (PEM) for your App: `https://github.com/organizations/<org>/settings/apps/<app-name>` (Hit `Generate a privat key` at the bottom of the page)
    - Also take note of the `App ID` shown at the top of that page
4. Note the Installation ID for the App installation in your organization
    - You can see it in the URL when you open your app from the app list: `https://github.com/organizations/<org>/settings/installations/<app-inst-id>`
    - Alternatively you can look it up using the [GitHub API](https://docs.github.com/en/rest/reference/apps#list-installations-for-the-authenticated-app)
5. Run git-sync with the GitHub App Details, e.g. 
    ```bash
    git-sync \
      --gh-app-id=<app-id> \
      --gh-app-inst-id=<app-inst-id> \
      --gh-app-pem=/path/to/gh-app.pem
    ```

### Kubernetes Manifest Snippet

Pre-Requisite: A Kubernetes secret named `git-sync-gh-app` that holds the GitHub App's PEM-File in the `app.pem` key's value

```yaml
# Deployment Manifest (incomplete)
spec:
  template:
    spec:
      containers:
        - name: git-sync
          env:
            - name: GIT_SYNC_GH_APP_ID
              value: 12345
            - name: GIT_SYNC_GH_APP_INST_ID
              value: 54321
            - name: GIT_SYNC_GH_APP_PEM
              value: /github/app.pem
          volumeMounts:
            - name: gh-app-pem
              mountPath: /github/app.pem
              subPath: app.pem
      volumes:
        - name: gh-app-pem
          secret:
            secretName: git-sync-gh-app
```