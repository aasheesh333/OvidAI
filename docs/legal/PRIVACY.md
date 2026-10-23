# Ovid Si Privacy Policy

**Last updated:** 21 October 2026

**Applies to:** the Ovid Si Android app (`com.dhanuk.ovidai`) and the Ovid Si
cloud service at [ovidsi.com](https://ovidsi.com).

Ovid Si is provided by **Dhanuk Softwares** ("Ovid", "we", "us"). This policy
explains what we collect, why we collect it, who processes it, how long we keep
it, and how you can delete it. It is meant to be read, not endured. If anything
is unclear, email **support@ovidsi.com**.

## The short version

- We collect what we need to run your account and the assistant: your sign-in
  identifier, your chats, the files you attach, your workspace files, usage and
  purchase status, and crash reports, diagnostics and usage analytics only if
  you turn them on.
- We do not sell your data, show ads, use an advertising ID, or use your chats
  or files to train our own models.
- Your prompts, files and relevant chat context are sent to the model providers
  that generate the answer, and to the infrastructure providers listed below.
- You can delete a chat, export your data, turn off crash reports, and delete
  your account in the app or on the web. Account deletion has a **24-hour grace period**;
  after that it cannot be undone.
- Ovid Si is for adults (**18+**). It is not directed at children.

## 1. Who is responsible for your data

Dhanuk Softwares is the data controller for the account and content data
described in this policy. That means we decide why and how it is processed.

You can contact us about privacy at **support@ovidsi.com**. Put "Privacy" in the
subject line so your message reaches the right place. You can also ask us for
our current business address and grievance contact details.

Ovid Si runs in the cloud. The Android app is a thin client: when you send a
message, the app sends it to our servers, and our servers run the assistant,
store your workspace and talk to model providers. Some data also stays on your
device as described in section 2.5.

## 2. What we collect

### 2.1 At a glance

| What | Examples | Why | Do you have to give it? |
|---|---|---|---|
| **Account and sign-in** | Email address or phone number, Firebase user ID, sign-in provider, display name or profile photo if your provider shares it | Create and secure your account, sign you in, support you | Yes |
| **Chats and memory** | Prompts, replies, model and agent activity, session and project memory, chat titles, search index | Run the assistant and show your history | Yes, to use chat |
| **Files and workspace** | Attachments, generated images, code, documents, Studio repo files, downloads, artifacts | Do the work you ask for and store the result | Only when you attach or create them |
| **Browser activity** | Pages the agent opens, page content, text typed into forms, cookies and saved logins | Let the agent browse and keep you signed in | Only when you use the browser |
| **Studio and connectors** | GitHub repository and branch, commits, connector accounts, API keys you add | Connect the tools you choose | Only when you connect them |
| **Usage and plan** | Token counts, runs, storage used, model choice, plan, limits, timestamps | Enforce limits, show usage, prevent abuse | Yes |
| **Purchases** | Plan, entitlement, purchase and renewal status, store transaction ID, refund status | Provide paid plans and meet accounting rules | Required for a paid plan |
| **Device and push** | Firebase Cloud Messaging token, platform, app version | Send notifications you asked for and keep the app working | Only if you allow notifications |
| **Crash reports and usage analytics** (optional) | Stack trace, app state at the crash, device model, OS and app version, performance timing, basic feature-usage events | Find and fix crashes and slowness, and understand which features are used | No - off unless you turn it on |
| **Reports and support** | The reason and note you submit with a report, a short excerpt, your support emails | Review reports and answer you | Only when you contact us |
| **Technical and security data** | IP address, request time, endpoint, status, app version, rate-limit and abuse signals, App Check result | Keep the service secure and available | Generated when you use the service |
| **Search** | Search terms you ask Ovid to use, and the chat text we index | Find past work and answer your search | Only when you search |

### 2.2 Account and sign-in

You can sign in with Google or with a phone number. We receive:

- your Google account identifier and email address, or your phone number;
- a Firebase user ID that identifies your Ovid account;
- basic profile details your sign-in provider chooses to share, such as a
  display name or profile photo. We use these only to show your account.

We do not ask for your password. Google sign-in happens with Google, and phone
sign-in uses a one-time code. We never see your Google password or your phone's
unlock code.

### 2.3 Chats, memory and files

When you use Ovid Si, we store:

- your messages and the assistant's replies;
- the steps the agent takes, such as tool calls, approvals, run status and
  errors;
- session memory, project memory and global memory, which help Ovid remember
  useful context;
- files, images and code you attach, and files the agent creates;
- workspace files for Studio, including a clone of the repository you choose;
- artifacts such as generated images, documents, code and data;
- schedules you create and the results of their runs.

Chats, memory and files are private to your account unless you choose to share
them. They are not public by default.

### 2.4 Browser and Studio

The browser runs in the cloud. When you use it, we process the pages the agent
opens, page content, text entered into forms, downloads and cookies, so the
agent can act for you and keep sessions signed in. Saved browser profiles and
any login credentials you choose to save are encrypted. Live view frames are
streamed to your device so you can watch the browser. Websites you open can
collect their own data under their own privacy policies; Ovid does not control
those sites.

When you connect GitHub for Studio, we receive the repository and branch you
select, the files needed to clone it, and the token or OAuth grant you approve.
The token is used to clone, fetch and push to that repository. It is not written
into the repository's `.git/config`.

Connectors and bring-your-own-key (BYOK) providers are optional. If you add one,
we store the credential you provide in encrypted form and use it only for the
connection you asked for.

### 2.5 Data on your device

The app keeps a cache of your chats, drafts, settings and sign-in state on your
device so it works offline and starts quickly. The cache stays on your device
and is refreshed from your account when you sign in. You can clear it by signing
out or clearing the app's data in Android settings. Deleting the app does not
delete your cloud account.

### 2.6 What we do not collect

The app does not ask for or read these from your device:

- your location. Our network providers process IP addresses for security and
  routing, which can indicate an approximate region, but we do not use that to
  track your location. If you allow a website you open in the in-app browser to
  use your location, that website receives it under its own policy; Ovid does
  not store it as location data;
- your contacts, calendar, SMS, call logs, health or fitness data, unless you
  connect a third-party connector that shares them, in which case section 2.4
  applies;
- your whole photo or video library - you pick a file through the system picker,
  and only the file you pick is uploaded;
- your advertising ID, and we do not show ads;
- biometric data. If you turn on app lock, Android checks your fingerprint or
  face and tells the app only whether the check succeeded.

Voice input is different: when you tap the microphone, the app asks Android for
microphone permission, turns your speech into text on your device, and sends
only the text. Ovid does not receive or store the audio.

## 3. Why we use your data

We use your data to:

- **provide the service** - create your account, run the assistant, execute
  tools, store your workspace, show your history and keep sessions isolated;
- **process payments** - manage plans, entitlements, renewals and refunds;
- **keep the service safe** - authenticate requests, apply rate limits, detect
  abuse, investigate attacks and enforce our Terms;
- **support you** - answer questions, fix problems and handle deletion or
  privacy requests;
- **improve reliability** - diagnose crashes, performance and feature usage,
  but only from the reports you turn on, and never by reading your
  prompts or files for that purpose;
- **meet the law** - keep records we are required to keep and respond to lawful
  requests.

If you are in the EEA, UK or Switzerland, our legal bases are:

| Purpose | Legal basis |
|---|---|
| Creating your account and providing the service | Performance of our contract with you |
| Payments, invoices and tax records | Performance of the contract and legal obligation |
| Security, fraud prevention and abuse detection | Our legitimate interests in protecting the service and our users |
| Customer support | Performance of the contract and our legitimate interests |
| Crash reports, diagnostics and usage analytics | Your consent |
| Notifications | Your consent, or our legitimate interest in service messages |
| Legal claims and compliance | Legal obligation and our legitimate interests |

Where we rely on legitimate interests, we balance our interests against your
rights. You can object at any time using the contact details below. Where we rely
on consent, you can withdraw it at any time; this does not affect processing
that already happened.

## 4. AI processing and model providers

Ovid Si does not run a model on your phone. When you ask a question, we send the
prompt, the relevant recent conversation, any files or images you attach, and
relevant memory to the model provider that will generate the answer. The request
goes through our own model gateway (we run the open-source **LiteLLM** gateway on
our servers) so we can route models, enforce plan limits and keep provider keys
away from your device.

The model providers we use include **Anthropic**, **Google** and **[OI]**, and
may include others shown in the app. If you add your own BYOK provider, we send
requests to the provider you chose using your key, and that provider's terms and
privacy practices apply.

Model providers process your prompts and related content to produce the answer.
Their retention and training practices are governed by their own terms. We do not
use your chats, files or outputs to train our own models, and we do not sell
them. Because AI output can be wrong, read it before you rely on it, especially
for code, law, medicine, money or safety.

Please do not submit information you do not have the right to share, and do not
send passwords, full card numbers or government identifiers in a chat.

## 5. Who processes your data

We use the following service providers. They process data on our instructions,
or under their own terms where noted.

| Provider | What it does for Ovid Si | Data involved |
|---|---|---|
| **Google - Firebase** (Authentication, Cloud Messaging, Crashlytics, Analytics, App Check / Play Integrity) | Sign-in, push notifications, optional crash reports and diagnostics and analytics, app verification | Account identifiers, email or phone, push token, device and app information, crash traces, analytics events, IP address |
| **Google Play** | Sells and bills subscriptions and processes payments | Purchase and subscription status, country, payment details handled by Google |
| **RevenueCat** | Keeps subscription entitlements in sync with Google Play | App user ID (your Firebase ID), purchase and entitlement status |
| **Cloudflare** (including R2 object storage) | CDN, DNS, TLS, firewall and DDoS protection; stores files and backups | Traffic and security metadata; account content stored at rest |
| **LiteLLM** | Open-source model gateway that we run on our own servers | Prompts, replies, model choice and token usage |
| **Model providers** (for example Anthropic, Google and [OI], or a BYOK provider you add) | Generate replies, code and images | Prompts, relevant chat context, files and images you send |
| **GitHub** | Connects Studio to the repository you choose | Repository data and the token or OAuth grant you approve |
| **Other connectors you add** | Let Ovid work with a service you choose | Depends on the connector and what you ask it to do |

Google, Cloudflare, RevenueCat, GitHub and the model providers are separate
companies. Some of them act under their own terms and privacy policies. We
require providers that process data for us to protect it and use it only to
provide their service to us. We do not let them use your data for their own
advertising.

**We do not sell your personal data. We do not share it for cross-context
behavioural advertising. We do not use advertising IDs. We do not use data
brokers.**

We may disclose data if the law requires it, if we need to enforce our Terms, or
to protect someone's safety. If we sell or reorganise our business, data may be
transferred as part of that transaction, subject to this policy.

## 6. When you choose to share

Some features are designed to share. These are your choices, not our sharing for
advertising:

- **Share links.** When you share a chat, we create a public snapshot at an
  unguessable link. Anyone with the link can view it for up to **30 days**, or
  until you revoke it. Do not post a link publicly if the chat contains private
  information. A recipient can fork the snapshot into their own account, and
  that copy then belongs to them.
- **Collab.** When you invite people to a Collab session, members can see the
  session's messages and the files included in it, and the session owner can
  remove members. The creator pays for the session's storage. If you leave, or
  the owner removes you, messages you already sent may remain in the session.
- **Reports.** If you report content, we receive the report, a short excerpt and
  your account ID so we can review it.

We cannot delete a copy that someone else has already saved or forked. If a
public link is indexed by a search engine, revoking the link stops our copy from
being served, but third-party caches may take time to update.

## 7. Cookies, ads and tracking

The app does not contain advertising SDKs, does not use an advertising ID, and
does not track you across other apps or websites. Firebase uses app instance
identifiers to deliver notifications, verify the app and, only with your
consent, collect crash, diagnostic and usage data.

Our public policy pages are plain HTML. Cloudflare may set a security cookie to
protect the site. We do not use advertising cookies. If we add analytics cookies
to the website, we will update this policy and ask for consent where required.

## 8. Where your data is stored

Our servers and those of our providers may be in Canada, the United States, the
European Union, India or other countries. Your data may be processed in a
country different from yours. Where the law requires it, we use contractual and
organisational safeguards for these transfers. By using Ovid Si, you understand
that your data may be processed outside your country.

We do not store your full payment card details. Google Play handles card data.
We receive only the purchase and subscription information needed to give you
your plan.

## 9. How long we keep your data

We keep data only as long as we need it for the purposes above, or as the law
requires. In practice:

| Data | How long we keep it |
|---|---|
| **Account and profile** | Until you delete your account, plus the 24-hour grace period. We keep a minimal deletion record after that (see section 12). |
| **Chats, memory, files, artifacts and workspace** | While your account is open and until you delete them. When you delete a chat or file, it disappears from the app and can no longer be read or used. Residual copies may remain in encrypted backups and integrity records until they expire, or until you delete your account. |
| **Live run events** | 24 hours in our fast event store, so a reconnect can catch up. |
| **Technical run archive** | Up to 30 days, for debugging and usage accounting. |
| **Crash reports, diagnostics and usage analytics** | Normally up to 90 days, and only if you turned them on. |
| **Usage and billing records** | While your account is open, and afterwards for as long as tax, accounting, fraud-prevention or other law requires. |
| **Share links** | Up to 30 days from creation, or until you revoke them. We keep a receipt record after the content is purged. |
| **Reports** | Up to 180 days, or longer if needed for a safety or legal investigation. |
| **Support messages** | While we handle your request and for a reasonable period afterwards. |
| **Security and rate-limit logs** | Normally no more than 30 days. |
| **Backups** | Up to 14 days, then they rotate out. |

We may keep aggregated or de-identified information that cannot identify you.
We may keep data longer if a law, court order or legal claim requires it, or if
we must keep it to prevent serious abuse.

## 10. How we protect your data

Data is encrypted in transit: we use HTTPS and WSS for traffic between the app,
our servers and our providers. Sensitive data at rest, such as provider keys and
browser profiles, is encrypted. We also use per-user workspaces, access controls,
rate limits, App Check / Play Integrity, and monitoring. Our application logs are
designed not to contain passwords, provider keys, prompts or file contents.

No system is perfectly secure. If we become aware of a breach that affects your
personal data, we will notify you and the relevant authorities as required by
law. You can help by keeping your device and sign-in secure, using app lock if
you want it, and telling us promptly at **support@ovidsi.com** if you think
someone else has access to your account.

## 11. Your choices and rights

You can:

- **See and export your data.** Open Settings to export your chats and data.
- **Correct your account details.** Update them in the app, on the web, or contact us.
- **Delete a chat or file.** Use the delete action in the app or on the web.
- **Delete your account.** Use Settings or the web page described in section 12.
- **Turn crash reports and usage analytics on or off.** Go to Settings ->
  Data control -> Crash reports. They are off by default.
- **Turn notifications off.** Use Settings -> Notifications or Android's app
  settings.
- **Withdraw consent.** Use the relevant toggle, or contact us. Withdrawing
  consent stops future processing but does not undo past processing.
- **Object or ask us to restrict processing.** Contact us and tell us what you
  want and why.
- **Complain.** Contact us first, or complain to your local data protection
  authority.

To exercise a right, email **support@ovidsi.com** from the address or phone
number linked to your account, or tell us your Ovid user ID. We may ask you to
verify that you control the account before we act, so that no one else can
access or delete your data. We do not charge for a normal request. If a request
is clearly unfounded or excessive, we may charge a reasonable fee or refuse it
as the law allows. We do not treat you differently for exercising your rights.

If you use an authorised agent, we may ask for proof of their authority. If we
cannot verify a request, we will explain why.

## 12. Deleting your account and your data

You can delete your Ovid account in the app or on the web:

1. Open **Settings -> Account -> Delete account**.
2. Confirm the deletion. Your account is scheduled for deletion, not erased
   immediately.
3. You have **24 hours** to change your mind. During that time, sign in again and
   choose **Restore account**. If you do nothing, deletion starts when the grace
   period ends.
4. After the grace period, deletion cannot be undone.

You can also request deletion without the app at
**[ovidsi.com/delete-account](https://ovidsi.com/delete-account)**, or by
emailing **support@ovidsi.com**.

When deletion completes, we delete or de-identify:

- your account record, email or phone number and sign-in link;
- your chats, messages, memory, files, workspace, artifacts and browser state;
- your schedules and run history;
- your share links, so they stop working;
- your Collab memberships;
- your BYOK keys, connector credentials and saved browser logins;
- your push tokens;
- reports you submitted and your support records, unless we must keep them for
  a legal or safety reason.

Some things remain:

- **Backups.** Encrypted backups that already contain your data expire within
  **14 days**.
- **Deletion record.** We keep a minimal record that the account was deleted,
  such as a random account identifier and the deletion time, to honour the
  deletion and prevent abuse. It does not contain your chats or files.
- **Billing and tax records.** We may keep purchase records where accounting,
  tax or fraud-prevention law requires it.
- **Other people's copies.** A chat that someone forked into their own account,
  or content you contributed to a Collab session owned by someone else, belongs
  to that account and is not deleted by deleting yours.
- **Aggregated data.** We may keep statistics that no longer identify you.

**Deleting your account does not cancel a Google Play subscription.** Cancel the
subscription in Google Play -> Payments and subscriptions. Otherwise Google Play
may keep charging you even though the Ovid account is gone.

If you need help with deletion, or a deletion request seems stuck, email
**support@ovidsi.com**.

## 13. Children

Ovid Si is for adults. You must be at least **18** years old to use it. It is not
directed at children, and we do not knowingly collect personal data from anyone
under 18. If we learn that a child has created an account, we will delete the
account and its data. If you believe a child is using Ovid Si, email
**support@ovidsi.com** and tell us the account details you have.

## 14. Regional privacy rights

### 14.1 EEA, UK and Switzerland

If you are in the EEA, the UK or Switzerland, you have the right to:

- access your personal data and get a copy;
- correct inaccurate data;
- delete data;
- restrict or object to processing;
- receive your data in a portable format;
- withdraw consent;
- complain to your local supervisory authority.

We normally respond within one month. If a request is complex, we may extend that
by up to two months and will tell you why. You can contact your local authority
at any time. We would appreciate the chance to resolve your concern first.

### 14.2 India

If you are in India, the Digital Personal Data Protection Act, 2023 gives you
rights to access, correct and erase your personal data, to grievance redressal,
to withdraw consent, and to nominate someone to exercise your rights in the
event of death or incapacity. You can exercise them at **support@ovidsi.com**.
We aim to respond within 30 days. If you are not satisfied, you can complain to
the Data Protection Board of India.

We process account and service data to perform our contract with you and for
purposes permitted by law. Optional crash reports, diagnostics and usage
analytics are based on your consent, which you can withdraw at any time.

### 14.3 California and other US states

If you are a California resident, you have the right to know what personal
information we collect, to access it, to delete it, to correct it, to opt out of
its sale or sharing, to limit the use of sensitive personal information, and not
to be discriminated against for exercising these rights. You can also use an
authorised agent.

We do not sell personal information. We do not share it for cross-context
behavioural advertising. We do not use sensitive personal information to infer
characteristics about you. To make a request, email **support@ovidsi.com**. We
will verify your identity before acting.

Residents of other US states with similar privacy laws can contact us using the
same address, and we will honour the rights those laws provide.

### 14.4 Other regions

If your local law gives you rights over your personal data, contact us at
**support@ovidsi.com** and we will help. This includes rights to access,
correction, deletion, portability and objection. Nothing in this policy limits a
right that your local law does not allow us to limit.

## 15. Changes to this policy

We may update this policy when the service or the law changes. We will post the
new version at [ovidsi.com/privacy](https://ovidsi.com/privacy) and change the
"Last updated" date. If a change is material, we will notify you in the app or
by email before it takes effect, and we will ask for consent again where the law
requires it. The previous version is available on request.

## 16. Contact and complaints

**Privacy and data requests:** support@ovidsi.com

**Support:** support@ovidsi.com

**Post:** ask us at the email above for our current business address.

We take complaints seriously. Tell us what happened and give us a chance to fix
it. If you are not satisfied with our answer, you can complain to your local data
protection authority or, in India, to the Data Protection Board of India.
