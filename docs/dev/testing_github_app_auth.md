# Testing GitHub app auth

## Step 1: Create and install a dummy GitHub app for testing with

Go to https://github.com/settings/apps/new

1. Enter a name for the app (needs to be unique across GitHub).
2. Set the required `homepage URL` field (can be any valid URL).
3. Under `Webhook`, uncheck the `Active` checkbox.
4. Click on `Repository permissions` under `Permissions`, and set `Contents` to `Read-only`
5. Click on `Create GitHub App` at the bottom of the page.
6. You should be navigated to a new page with a `Registration successful. You must generate a private key in order to install your GitHub App.` message. Click on the `generate a private key` link, and then the `Generate a private key` button, and save it somewhere; it will be used to test the app authentication.
7. Click on the `Install App` tab on the left, and then click on `Install` on the right.
8. Select `Only select repositories`, and pick any private repository that contains a "LICENSE" file (may need to be created beforehand).

## Step 2: Export the necessary environment variables

The following environment variables are *required* to run the git-sync GitHub app auth tests:
- `TEST_GITHUB_APP_PRIVATE_KEY` or `TEST_GITHUB_APP_PRIVATE_KEY_FILE`. If both are set, `TEST_GITHUB_APP_PRIVATE_KEY` overwrites `TEST_GITHUB_APP_PRIVATE_KEY_FILE`.
- `TEST_GITHUB_APP_APPLICATION_ID`
- `TEST_GITHUB_APP_CLIENT_ID`
- `TEST_GITHUB_APP_INSTALLATION_ID`
- `TEST_GITHUB_APP_AUTH_TEST_REPO`

### TEST_GITHUB_APP_PRIVATE_KEY
The content of the GitHub app's private key file. It should have been saved when creating the app.
If `TEST_GITHUB_APP_PRIVATE_KEY_FILE` is also set, it overwrites the file with the content.
Otherwise, it saves the content to `/tmp/git-sync-e2e.random-id/github_app_private_key.pem`.

### TEST_GITHUB_APP_PRIVATE_KEY_FILE
The absolute path to the file that stores the GitHub app's private key file. It should have been saved when creating the app.

### TEST_GITHUB_APP_APPLICATION_ID
The value after "App ID" in the app's settings page.

### TEST_GITHUB_APP_CLIENT_ID
The value after "Client ID" in the app's settings page.

### TEST_GITHUB_APP_INSTALLATION_ID
Found in the URL of the app's installation page if you installed it to a repository: https://github.com/settings/installations/<installation_id>

### TEST_GITHUB_APP_AUTH_TEST_REPO.
Should be set to the repository that the GitHub app is installed to.
