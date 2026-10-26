/**
 * The published privacy policy (owner, 2026-10-25). The working copy, with the points counsel still
 * has to confirm, is the shared "Suskii Errands — Privacy Policy (draft)" doc; change the policy there
 * first and copy it here. English only: the pcm locale shows the same text.
 */

export type PolicyBlock =
  | { kind: 'p'; text: string }
  | { kind: 'list'; ordered?: boolean; items: string[] }
  | { kind: 'table'; head: string[]; rows: string[][] };

export type PolicySection = { heading: string; blocks: PolicyBlock[] };

export const privacyPolicy: { updated: string; sections: PolicySection[] } = {
  updated: '26 October 2026',
  sections: [
    {
      heading: 'Who we are',
      blocks: [
        {
          kind: 'p',
          text: 'Suskii Errands is a marketplace that connects people who need errands, shopping, deliveries and similar tasks done with independent providers who do them. This policy covers the Suskii Errands app on Android and iOS, the website at suskiierrand.com, and the customer web app at app.suskiierrand.com.',
        },
        {
          kind: 'p',
          text: 'The data controller is Suskii Errands ("Suskii", "we", "us"). You can reach us about privacy at privacy@suskiierrand.com. If we appoint a Data Protection Officer, their contact details will appear here.',
        },
      ],
    },
    {
      heading: 'What we collect',
      blocks: [
        {
          kind: 'p',
          text: "We collect what you give us, what the app records while you use it, and a little from the services you sign in or pay with. We do not read your phone's contact list, and we do not collect your calendar, SMS, call logs, installed apps, browsing history, health data, advertising ID or background location.",
        },
        {
          kind: 'table',
          head: ['Category', 'What', 'When'],
          rows: [
            ['Account', 'Phone number or email address, a unique account ID, and the country your account is created in', 'When you sign up or sign in'],
            ['Profile', 'Your name (required for providers, optional for customers), photo, preferred language and time zone', 'When you fill in your profile'],
            ['Errands', 'Pickup and drop-off addresses, landmarks, access notes, descriptions, photos, prices, offers, and the history of each job', 'When you post, accept or carry out an errand'],
            ['Location', 'See the Location section below', 'Only while you use certain features'],
            ['Messages and calls', 'Chat messages and images with the other person on a job; for calls, who called whom, when and for how long. Calls are never recorded', 'When you use chat or calls'],
            ['Identity verification', 'Government ID number, photos of documents, a selfie, and for providers a police clearance certificate', 'When you become a provider, or when a limit requires it'],
            ['Payments', "Amounts, payment references, refunds, tips and promo codes. Card and bank details are entered on the payment provider's own page; we never receive your card number", 'When you pay'],
            ['Payouts', "Providers' bank account details for withdrawals, stored encrypted", 'When a provider adds a payout account'],
            ['Safety', 'Up to five trusted contacts (names and phone numbers, stored encrypted), SOS alerts and trip-share links you create', 'When you use safety features'],
            ['Suskii Meet', 'Meet-ups you create or join, and the venue you choose. Others see your first name only', 'When you use Suskii Meet'],
            ['Ratings, reports and support', 'Ratings and reviews, reports about users or content, support tickets and disputes', 'When you send them'],
            ['Referrals', 'Your referral code, who you referred or were referred by, and referral earnings', 'When you use the referral programme'],
            ['Device and security', 'Device identifiers, the push token if you allow notifications, app integrity checks from Google Play and Apple, IP address, app version, and crash reports', 'Automatically, to keep accounts secure and the app working'],
            ['Sign-in providers', 'Your name and email address from Google or Apple, if you choose to sign in with them', 'When you use that sign-in option'],
          ],
        },
      ],
    },
    {
      heading: 'How we use it and why we are allowed to',
      blocks: [
        {
          kind: 'p',
          text: 'We use your data to run the marketplace, keep people safe, and meet the law. We do not sell personal data, and the app shows no advertising. The lawful bases below are those of the Nigeria Data Protection Act 2023.',
        },
        {
          kind: 'table',
          head: ['Purpose', 'Lawful basis'],
          rows: [
            ['Creating and securing your account, signing you in', 'Contract'],
            ['Matching errands with nearby providers, offers, negotiation and carrying out the job', 'Contract'],
            ['Payments, refunds, payouts, tips and keeping financial records', 'Contract; legal obligation for tax and accounting records'],
            ["Verifying providers' identity and police clearance, and customers' identity when a limit requires it", 'Explicit consent for the selfie and other sensitive data; legal obligation where anti-money-laundering rules apply'],
            ["Live location during an active job, and an online provider's position for matching", 'Contract'],
            ['Safety features: SOS, trip sharing, trusted contacts', 'Contract; vital interests in an emergency'],
            ['Preventing fraud and abuse, and moderating content', 'Legitimate interests'],
            ['Support, disputes and complaints', 'Contract; legitimate interests'],
            ['Service messages about your errands and account', 'Contract'],
            ['Marketing messages, if we send any', 'Consent, which you can withdraw at any time'],
            ['Product analytics, using pseudonymised data', 'Legitimate interests; you can object'],
          ],
        },
        {
          kind: 'p',
          text: 'Automated decisions: our fraud checks can flag an account for review, but they never ban or suspend anyone by themselves. A person reviews every flag, and you can appeal any decision on your account.',
        },
      ],
    },
    {
      heading: 'Location',
      blocks: [
        {
          kind: 'p',
          text: "We use precise location only while the app is open and only for the features below; we never track you in the background. You can turn location off in your phone's settings and still use the app, by setting places on the map by hand.",
        },
        {
          kind: 'table',
          head: ['When', 'What we use', 'Who sees it', 'How long we keep it'],
          rows: [
            ['You tap "use my location" for a pickup', "Your current position, saved as the errand's pickup point", 'The provider assigned to the errand', "With the errand's record"],
            ['A provider is online, with the app open', 'Their position, refreshed about every 45 seconds, to find nearby errands', 'No other user; used only for matching', 'Overwritten by the next update'],
            ['A provider is on an active job', 'Their live position, and their position when they mark arrival', 'The customer on that job, live; afterwards, a dispute officer only if a dispute names that job', '90 days, then deleted, unless a dispute needs it'],
            ['You browse Suskii Meet', 'Your position, to sort meet-ups by distance', 'Nobody', 'Not stored'],
            ['You create an account', 'Your country only, worked out on your phone from the mobile network, SIM, time zone or region setting, without location permission', 'Not shown to other users', 'With your account'],
          ],
        },
        { kind: 'p', text: 'Support staff never see location history.' },
      ],
    },
    {
      heading: 'Who we share it with',
      blocks: [
        {
          kind: 'p',
          text: 'We share personal data only with the people and companies below, and only what each needs. Companies that process data for us do so under contract and may not use it for their own purposes.',
        },
        {
          kind: 'table',
          head: ['Recipient', 'What they receive', 'Why'],
          rows: [
            ['The other person on an errand', "Name, rating, pickup and drop-off, messages, and the provider's live position during the job", 'To carry out the errand you asked for'],
            ['Supabase', 'Account, profile, errands, messages, payment records and files', 'Hosts our database, sign-in and file storage'],
            ['Google Cloud', 'Encrypted backups, monitoring data and security keys', 'Backups, monitoring and key storage'],
            ['Cloudflare', 'Website visits (IP address, pages requested)', 'Hosts and protects our websites'],
            ['Google Maps', 'Map requests from your device', 'Draws maps in the app'],
            ['Google Firebase Cloud Messaging', "Your device's push token, and a notification that names nothing: our name, a generic line and an internal id", 'Delivers the push notifications you allowed'],
            ['Google Play and Apple', 'Device integrity checks; app store purchase and install data', 'Protect accounts from tampered apps; distribute the app'],
            ['Payment providers', 'Amount, reference, and the card or bank details you enter on their page', 'Process payments, refunds and payouts'],
            ['Identity verification provider', 'ID number, document photos and selfie', 'Check identity and liveness'],
            ['Messaging providers', 'Your phone number or email address and the one-time code', 'Send sign-in codes and service messages'],
            ['Crash reporting, when switched on', 'Crash reports without your name, account ID or messages', 'Fix app errors'],
            ['Your trusted contacts', 'The route and status of a trip you share', 'You chose to share it'],
            ['Emergency partners', 'Your position and job details during an SOS', 'Help in an emergency you raised'],
            ['Authorities and courts', 'What the law requires', "When we are legally required, or to protect someone's safety"],
          ],
        },
        {
          kind: 'p',
          text: 'If Suskii is sold or merged, your data may pass to the new owner under this policy, and we will tell you first.',
        },
      ],
    },
    {
      heading: 'Where your data is stored',
      blocks: [
        {
          kind: 'p',
          text: "Our database, files and backups are stored in London, United Kingdom: Supabase's eu-west-2 region and Google Cloud's europe-west2 region. Our websites are served from Cloudflare's network, which answers each visitor from a data centre near them.",
        },
        {
          kind: 'p',
          text: "Storing data outside Nigeria is a cross-border transfer under the NDPA. We make these transfers only with the safeguards the NDPA allows, including the data processing agreements each provider has with us. Payment, identity and messaging providers may process data in other countries under their own agreements with us.",
        },
      ],
    },
    {
      heading: 'How long we keep it',
      blocks: [
        {
          kind: 'p',
          text: 'We keep data only as long as the purpose needs, then delete it automatically; a dispute, legal claim or investigation can pause deletion until it ends.',
        },
        {
          kind: 'table',
          head: ['Data', 'How long', 'Counted from'],
          rows: [
            ['Payment and accounting records', '7 years', 'The transaction'],
            ['Security and audit logs', '7 years', 'The event'],
            ['Identity documents and police clearance', '5 years', 'Account closure'],
            ['Identity check results', 'The life of the account, plus 5 years', 'Account closure'],
            ['Proof-of-delivery photos', '24 months', "The job's closing"],
            ['Chat messages, images and call records', '12 months', "The job's closing, or the call's end"],
            ['Job location trail', '90 days', "The job's closing"],
            ['Marketing consent records', 'The life of the consent, plus 3 years', 'Withdrawal'],
          ],
        },
        { kind: 'p', text: 'Everything else is deleted when you delete your account, as described below.' },
      ],
    },
    {
      heading: 'How we protect it',
      blocks: [
        {
          kind: 'p',
          text: 'We protect your data with encryption, strict access rules and logging; no system is perfectly secure, but these limit who can see what.',
        },
        {
          kind: 'list',
          items: [
            'All traffic between the app, the websites and our servers is encrypted in transit.',
            'The database lets each person read only their own data and what an errand they are part of needs.',
            "ID numbers, payout bank accounts, trusted contacts' phone numbers and access notes are encrypted inside the database. The keys are held separately, with a protected backup copy.",
            'Identity documents sit in private storage that apps cannot read. Staff open them only through short-lived links, and every view is logged.',
            'Staff tools sit behind an extra sign-in layer, and staff see only what their role and country need.',
            'The app checks with Google Play and Apple that it has not been tampered with.',
          ],
        },
        {
          kind: 'p',
          text: 'If a breach is likely to put your rights at risk, we will tell the Nigeria Data Protection Commission and, where required, you, within the time the law sets.',
        },
      ],
    },
    {
      heading: 'Your rights',
      blocks: [
        {
          kind: 'p',
          text: 'You can see, correct, export or delete your data, and object to how we use it. Under the NDPA you have the right to:',
        },
        {
          kind: 'list',
          items: [
            'access the personal data we hold about you;',
            'correct data that is wrong or incomplete;',
            'delete your data, subject to the records the law makes us keep;',
            'restrict how we use it while a complaint is checked;',
            'receive a copy in a portable format;',
            'object to uses based on legitimate interests, such as analytics;',
            'withdraw consent at any time, without affecting what was done before;',
            'ask for a person to review any decision about your account made by automated means.',
          ],
        },
        {
          kind: 'p',
          text: "You can edit your profile and request a copy of your data in the app's account settings, or write to us at privacy@suskiierrand.com. We reply without undue delay and within the time the law sets, and may ask you to prove who you are first.",
        },
      ],
    },
    {
      heading: 'Deleting your account',
      blocks: [
        {
          kind: 'p',
          text: 'You can delete your account at any time, free of charge, in the app (Profile, then Settings, then Delete account) or on the web; full steps are at suskiierrand.com/en/delete-account.',
        },
        {
          kind: 'list',
          ordered: true,
          items: [
            'You are signed out on every device straight away.',
            'For 30 days you can change your mind by signing in again and choosing Keep my account.',
            'After 30 days your name, phone number, email address, trusted contacts and favourites are erased, and the account can no longer be signed in to.',
            'Records of jobs you took part in, such as payments, refunds, payouts, messages and proofs, stay with those jobs for the periods in How long we keep it, without your contact details.',
          ],
        },
        {
          kind: 'p',
          text: 'Open jobs, open disputes or money left in your wallet must be settled before deletion; the app tells you if one is in the way.',
        },
      ],
    },
    {
      heading: 'Age limit',
      blocks: [
        {
          kind: 'p',
          text: 'Suskii Errands is for adults only: you must be 18 or older to use it, as a customer or a provider. We do not knowingly collect data from anyone under 18; if we learn we have, we delete the account.',
        },
      ],
    },
    {
      heading: 'Changes to this policy',
      blocks: [
        {
          kind: 'p',
          text: 'We will post any change here with a new date at the top. If a change affects how we use your data in a significant way, we will tell you in the app before it takes effect.',
        },
      ],
    },
    {
      heading: 'Contact and complaints',
      blocks: [
        {
          kind: 'p',
          text: 'Write to us first at privacy@suskiierrand.com, and we will try to put it right. If you are not satisfied, you can complain to the Nigeria Data Protection Commission (NDPC), or to the data protection authority where you live.',
        },
      ],
    },
  ],
};
