import type { Dictionary } from './en';

const pcm = {
  meta: {
    title: 'Suskii Errands — errand, shopping and delivery for Nigeria',
    description:
      'Suskii Errands go connect you with verified providers wey go run errand, shopping, delivery, queue work and any custom request for cities across Nigeria.',
  },
  nav: {
    home: 'Home',
    howItWorks: 'How e take work',
    services: 'Services',
    becomeProvider: 'Become provider',
    businesses: 'For business',
    safety: 'Safety',
    referrals: 'Referral',
    faq: 'Questions',
    contact: 'Contact us',
    getTheApp: 'Get the app',
  },
  footer: {
    tagline: 'Send anything go anywhere.',
    exploreTitle: 'Explore',
    companyTitle: 'Company',
    legalTitle: 'Legal',
    privacy: 'Privacy policy',
    terms: 'Terms of service',
    cities: 'Cities',
    rights: 'Suskii Errands. All rights reserved.',
  },
  common: {
    learnMore: 'Learn more',
    getStarted: 'Start now',
    comingSoon: 'E dey come soon',
    downloadApp: 'Download the app',
    appStore: 'App Store',
    googlePlay: 'Google Play',
  },
  home: {
    heroTitle: 'Send anything go anywhere.',
    heroSubtitle:
      'Verified providers go handle your errand, shopping and delivery for your city — with live tracking and price wey una go agree before e start.',
    heroPrimaryCta: 'Get the app',
    heroSecondaryCta: 'How e take work',
    howTitle: 'How e take work',
    howTeaser: [
      {
        title: 'Tell us wetin you need',
        body: 'Describe the errand, the address and your budget with few taps.',
      },
      {
        title: 'We go match you',
        body: 'Verified provider go accept your request and una go agree the price before e start.',
      },
      {
        title: 'Track am till e done',
        body: 'Follow every step live until handover PIN confirm say e complete.',
      },
    ],
    servicesTitle: 'One app, plenty hands',
    servicesBody:
      'From market run to document delivery, providers for Suskii dey handle the tasks wey you no fit reach.',
    servicesCta: 'See services',
    safetyTitle: 'Safety for every errand',
    safetyBody:
      'Verified providers, SOS, trip sharing and handover PIN dey for every request — no be optional.',
    safetyCta: 'How we dey keep you safe',
    referralTitle: 'Dash small, collect small',
    referralBody:
      'Invite your padi dem to Suskii and both of una go earn wallet credit when dem complete their first errand.',
    referralCta: 'About referral',
    providerTitle: 'Earn on your own time',
    providerBody:
      'Join as provider and collect money for errands for your area, with payment straight into your Suskii wallet.',
    providerCta: 'Become provider',
  },
  howItWorks: {
    title: 'How Suskii take work',
    subtitle: 'Few taps for customers, clear job for providers.',
    forCustomersTitle: 'For customers',
    customerSteps: [
      {
        title: 'Describe the task',
        body: 'Pick service, add pickup and drop-off details, and set your budget.',
      },
      {
        title: 'Check the quote',
        body: 'You go see the full price and breakdown before anything move.',
      },
      {
        title: 'Match with provider',
        body: 'Verified provider near you go accept and waka go. Una fit chat or call inside the app.',
      },
      {
        title: 'Confirm handover',
        body: 'Track the progress live and confirm completion with your one-time PIN.',
      },
    ],
    forProvidersTitle: 'For providers',
    providerSteps: [
      {
        title: 'Sign up and verify',
        body: 'Create account, upload your ID and pass background check.',
      },
      {
        title: 'Pick jobs near you',
        body: 'See requests for your area with the full price showing before you accept.',
      },
      {
        title: 'Do the job',
        body: 'Clear instructions, in-app navigation and customer chat make everything smooth.',
      },
      {
        title: 'Collect your money',
        body: 'Money enter your Suskii wallet once the job complete. Withdraw anytime.',
      },
    ],
  },
  services: {
    title: 'Services',
    subtitle: 'Any task wey you get, provider dey for am.',
    categories: [
      {
        name: 'Errands',
        blurb: 'Pickup, drop-off, bank run and those small tasks wey dey chop your day.',
      },
      {
        name: 'Shopping',
        blurb: 'Market and supermarket run with photo confirmation before dem buy anything.',
      },
      {
        name: 'Deliveries',
        blurb: 'Document, parcel and food wey dem move across town, tracked live.',
      },
      {
        name: 'Queueing',
        blurb: 'Provider go hold your place for bank, office and embassy queue.',
      },
      {
        name: 'Custom requests',
        blurb: 'Something different? Describe am and our concierge go scope am.',
      },
    ],
  },
  providers: {
    title: 'Become provider',
    subtitle: 'Turn your time and your knowledge of the city into steady income.',
    requirementsTitle: 'Wetin you need',
    requirements: [
      'Smartphone wey get the Suskii app',
      'Valid government ID for verification',
      'Bank account for payment',
      'Better transport for delivery jobs',
    ],
    earningsTitle: 'Wetin you go earn',
    earningsBody:
      'You go see the full price before you accept, and your share go enter your Suskii wallet as soon as the job complete. Withdraw go your bank anytime you like.',
    cta: 'Apply inside the app',
  },
  businesses: {
    title: 'Suskii for business',
    subtitle: 'One console for all the errand, delivery and runs wey your team need.',
    points: [
      {
        title: 'Central billing',
        body: 'One monthly invoice for every request wey your team make.',
      },
      {
        title: 'Team roles',
        body: 'Invite staff, set spending limit and approve requests before dem go out.',
      },
      {
        title: 'Priority support',
        body: 'Dedicated line for business errands wey no fit wait.',
      },
    ],
    cta: 'Talk to us',
  },
  safety: {
    title: 'Safety for every errand',
    subtitle: 'Protection wey dey built-in for customers and providers.',
    features: [
      {
        title: 'Verified providers',
        body: 'Every provider pass ID and background check before their first job.',
      },
      {
        title: 'SOS',
        body: 'One-tap emergency alert dey available for every active job.',
      },
      {
        title: 'Trip sharing',
        body: 'Share live job progress with person wey you trust.',
      },
      {
        title: 'Handover PIN',
        body: 'Job no go complete until dem enter your one-time PIN.',
      },
    ],
  },
  referrals: {
    title: 'Referral',
    subtitle: 'Share Suskii, make una earn together.',
    steps: [
      {
        title: 'Share your code',
        body: 'Find your referral code inside the app and send am give your padi dem.',
      },
      {
        title: 'Dem run errand',
        body: 'Your padi sign up and complete their first request.',
      },
      {
        title: 'Both of una earn',
        body: 'Wallet credit enter for both of una — no limit to invites.',
      },
    ],
    cta: 'Get the app',
  },
  faq: {
    title: 'Questions wey people dey ask',
    items: [
      {
        q: 'Where Suskii dey available?',
        a: 'We dey live for Lagos and Abuja, and Port Harcourt, Ibadan and Kano go soon launch.',
      },
      {
        q: 'How much errand dey cost?',
        a: 'You go see the full price before you confirm. The quote dey based on distance, task type and current market price.',
      },
      {
        q: 'Who be the providers?',
        a: 'Providers na vetted members of your community wey pass ID and background check before dem fit take job.',
      },
      {
        q: 'How I go take pay?',
        a: 'Fund your Suskii wallet with card, bank transfer or USSD, then pay from your balance.',
      },
      {
        q: 'Wetin happen if something go wrong?',
        a: 'Every job get SOS, trip sharing and in-app support. Our team dey review disputes.',
      },
      {
        q: 'How providers dey collect money?',
        a: 'Money enter the provider wallet when job complete and dem fit withdraw am to bank account.',
      },
      {
        q: 'I fit use Suskii for my business?',
        a: 'Yes. The business console get central billing, team roles and priority support.',
      },
    ],
  },
  contact: {
    title: 'Contact us',
    subtitle: 'Question, partnership or press — we dey happy to help.',
    emailLabel: 'Email support',
    emailAddress: 'support@suskii.example',
    inAppTitle: 'In-app support',
    inAppBody:
      'The fastest help dey inside the app — go to Profile, then Support, and chat with the team.',
  },
  legal: {
    placeholderNote: 'Placeholder text wey dey wait for legal review.',
    privacyTitle: 'Privacy policy',
    privacyBody: [
      'This placeholder describe, for high level, how Suskii Errands go handle personal data: we only collect wetin we need to complete errands, we no dey sell personal data, and you fit ask us to delete your data anytime.',
      'The full policy — including how long we keep data, third-party processors and your rights under the Nigeria Data Protection Act — go dey published here before launch.',
    ],
    termsTitle: 'Terms of service',
    termsBody: [
      'This placeholder summarise the terms wey we intend: Suskii Errands na marketplace wey dey connect customers with independent providers; price dey show upfront; disputes dey handled through the in-app process.',
      'Binding terms — including liability, cancellation and refund — go dey published here before launch.',
    ],
  },
  cities: {
    title: 'Cities',
    subtitle: 'Where Suskii dey work today — and where we dey go next.',
    cta: 'Get the app',
  },
  city: {
    lagos: { name: 'Lagos', tagline: 'From Lekki to Ikeja, errands at Lagos speed.' },
    abuja: { name: 'Abuja', tagline: 'Errand wey you fit trust across the capital.' },
    'port-harcourt': {
      name: 'Port Harcourt',
      tagline: 'The Garden City, served street by street.',
    },
    ibadan: { name: 'Ibadan', tagline: 'Errands across the whole city of brown roofs.' },
    kano: { name: 'Kano', tagline: 'Commerce dey move faster with Suskii.' },
  },
  notFound: {
    title: 'Page no dey',
    body: 'The page wey you dey find no exist or e don move.',
    cta: 'Go back home',
  },
} satisfies Dictionary;

export default pcm;
