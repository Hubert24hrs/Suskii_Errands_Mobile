/**
 * The published terms of service (owner, 2026-11-21, OD-34: publish the draft now, counsel reviews
 * afterwards). Written for direct payment (ADR-0025): customers pay providers themselves and Suskii
 * holds no money. The working copy with the points counsel still has to confirm is the shared
 * "Suskii Errands — Terms of Service (draft)" doc; when in-app payments return, the payment,
 * cancellation, dispute and referral sections change with them. English only: the pcm locale shows
 * the same text.
 */

import type { PolicySection } from './privacy-policy';

export const termsOfService: { updated: string; sections: PolicySection[] } = {
  updated: '21 November 2026',
  sections: [
    {
      heading: 'About these terms',
      blocks: [
        {
          kind: 'p',
          text: 'These terms are the agreement between you and Suskii Errands ("Suskii", "we") for using the Suskii Errands app and websites. By creating an account or using the app you agree to them. If you do not agree, do not use Suskii.',
        },
        {
          kind: 'p',
          text: 'Our privacy policy, at suskiierrand.com/en/legal/privacy, explains how we handle your personal data and is part of these terms.',
        },
        {
          kind: 'p',
          text: 'We may change these terms. When a change matters to you, we tell you in the app or by email at least 14 days before it takes effect. If you keep using Suskii after that, the new terms apply. If you do not accept them, you can close your account.',
        },
      ],
    },
    {
      heading: 'Who can use Suskii',
      blocks: [
        {
          kind: 'list',
          items: [
            'You must be 18 or older, whether you post errands or run them.',
            'One account per person. Keep your sign-in codes to yourself; you are responsible for what happens on your account.',
            'Tell the truth about who you are. We may ask you to verify your identity, for example before you can work as a provider. Providers cannot take jobs until we have verified them.',
            "Business accounts may add team members and vehicles. The business is responsible for its members' use of Suskii.",
          ],
        },
        { kind: 'p', text: 'Suskii is available in Nigeria. Using it from elsewhere is at your own risk.' },
      ],
    },
    {
      heading: 'How Suskii works',
      blocks: [
        {
          kind: 'p',
          text: 'Suskii is a marketplace. Customers post errands; independent providers nearby send offers; the customer accepts one and agrees a price in the app.',
        },
        {
          kind: 'list',
          items: [
            'The agreement for an errand is between the customer and the provider. Suskii runs the app and helps when something goes wrong. Suskii does not employ providers and is not the seller of goods a provider buys for you.',
            'Prices are agreed in the app. The price on the accepted offer is the price for the job. The app keeps a record of it that both of you, and our support team, can see.',
            'Describe errands honestly, including anything fragile, heavy or valuable. A provider may decline or cancel an errand that turns out different from its description.',
            'Keep the job in the app. Chat and calls in the app are part of the job record and of our safety features; conversations outside the app are not.',
          ],
        },
      ],
    },
    {
      heading: 'Paying for an errand',
      blocks: [
        {
          kind: 'p',
          text: 'At the moment customers pay providers directly. Suskii does not collect, hold or pass on payment for errands, and is not a party to the payment.',
        },
        {
          kind: 'list',
          ordered: true,
          items: [
            'When you accept an offer, you confirm the hire in the app. Nothing is charged. The provider can then see your address and contact you in the app.',
            'The provider does the errand.',
            'When the job is done, you pay the provider the agreed price, in cash or by bank transfer, and confirm in the app that the job is done.',
          ],
        },
        {
          kind: 'list',
          items: [
            'Pay only the price agreed in the app, and only when the job is done. Never pay in advance.',
            'A provider must not ask for more than the agreed price, or for payment before the job is done. Report it to us if one does.',
            'Suskii charges customers and providers no fee at the moment. We will tell you at least 14 days before we start charging any fee or taking payment in the app.',
            'All amounts are in Nigerian naira.',
          ],
        },
      ],
    },
    {
      heading: 'Shopping errands',
      blocks: [
        {
          kind: 'p',
          text: 'When a provider buys goods for you, you set the most they may spend on them when you post the errand, and you both see it in the app.',
        },
        {
          kind: 'list',
          items: [
            'The provider pays for the goods and records what they cost, with a photo of the receipt, in the app before delivering them. The app does not accept more than the maximum you set.',
            'On delivery you repay the provider what the goods cost, as shown in the app, together with the agreed price.',
            'If the goods would cost more than your maximum, the provider should ask you in the chat before buying them.',
          ],
        },
      ],
    },
    {
      heading: 'Cancelling',
      blocks: [
        {
          kind: 'p',
          text: 'Either of you can cancel an errand in the app until the provider has marked it done. Because nothing is paid through the app, there is no cancellation fee and nothing to refund. Cancellations are recorded on the account that makes them, and repeated cancellations after a hire can lead to a suspension.',
        },
      ],
    },
    {
      heading: 'When something goes wrong',
      blocks: [
        {
          kind: 'p',
          text: 'Contact us from Support in the app, or at support@suskiierrand.com. We look at the job record: the agreed price, the chat, photos, receipts and the history of the job.',
        },
        {
          kind: 'list',
          items: [
            'Because Suskii does not hold the money, we cannot refund or recover a payment made between a customer and a provider.',
            'We can warn, suspend or close an account that breaks these terms, for example a customer who does not pay for completed work or a provider who overcharges.',
            'A person at Suskii decides, never someone involved in the job. Our decision does not stop you from using any legal remedy you have.',
          ],
        },
      ],
    },
    {
      heading: 'For providers',
      blocks: [
        {
          kind: 'list',
          items: [
            "You are independent. You choose which errands to offer on, set your own prices, and decide when you are online. You are not Suskii's employee or agent.",
            'Verification. Before your first job you pass identity checks; some categories and limits also need a police clearance. Keep your documents current: when one expires, you cannot take new jobs until it is renewed.',
            'Doing the job. Do what you offered, at the price you offered. Use the handover PIN where the app asks for one, and upload receipts and proof of delivery when asked.',
            'Getting paid. The customer pays you the agreed price, and what you spent on goods as recorded in the app, when the job is done. Do not ask for more, or for payment in advance.',
            'Taxes. You are responsible for tax on what you earn.',
            'Businesses. A business account is responsible for the members and vehicles it adds, and for checking that they may legally do the work.',
          ],
        },
      ],
    },
    {
      heading: 'Referrals',
      blocks: [
        {
          kind: 'p',
          text: 'You can invite people with your referral code, and the app records who you invited. While customers pay providers directly, referrals earn no cash. If that changes, we will announce the terms of the programme before it starts paying.',
        },
      ],
    },
    {
      heading: 'What is not allowed',
      blocks: [
        { kind: 'p', text: 'You may not use Suskii to buy, carry or deliver:' },
        {
          kind: 'list',
          items: [
            'firearms, ammunition or explosives;',
            'illegal drugs, or prescription medicine without a valid prescription;',
            'alcohol or tobacco for anyone under 18;',
            'counterfeit or stolen goods;',
            'cash or foreign currency;',
            'hazardous chemicals;',
            'human remains or live wild animals;',
            "pre-registered SIM cards, or anyone else's government ID.",
          ],
        },
        {
          kind: 'p',
          text: 'Or to arrange these services: debt collection by force, sex work, gambling agents, sitting exams for someone else, forging documents, unlicensed medical procedures, or armed escorts.',
        },
        {
          kind: 'p',
          text: "And on any errand, do not: harass, threaten or discriminate against anyone; share someone's contact details or location outside the job; ask for more than the agreed price or for payment in advance; refuse to pay for work that was done as agreed; post false reviews; or use the app to defraud anyone.",
        },
        {
          kind: 'p',
          text: 'We screen messages and errand descriptions for prohibited items and may remove content that breaks these rules. Removing content does not by itself close your account.',
        },
      ],
    },
    {
      heading: 'Safety features and their limits',
      blocks: [
        {
          kind: 'p',
          text: "The app has an SOS button on every active job, lets you add up to five trusted contacts, and can share a live trip link with someone you choose. During a job, the customer and provider can see each other's position.",
        },
        {
          kind: 'p',
          text: 'Suskii is not an emergency service. SOS alerts our team, who respond as fast as they can, but we cannot guarantee a response time or send help ourselves. If you are in danger, call the emergency services on 112 first.',
        },
        {
          kind: 'p',
          text: 'Report unsafe behaviour from the job or to support@suskiierrand.com. We review every report.',
        },
      ],
    },
    {
      heading: 'Suspension and closing your account',
      blocks: [
        {
          kind: 'p',
          text: 'We may suspend an account that breaks these terms, puts people at risk, or is under investigation for fraud. A suspension has an end date and is decided by a person, never automatically; we tell you why unless the law or a safety reason prevents it. While a provider is suspended they cannot take new jobs. For serious or repeated breaches we may close the account.',
        },
        {
          kind: 'p',
          text: 'You can close your account at any time from Settings in the app, or on the web at suskiierrand.com/en/delete-account. Jobs in progress are finished or cancelled first. What we keep afterwards, and for how long, is in the privacy policy.',
        },
      ],
    },
    {
      heading: 'Liability, governing law and contact',
      blocks: [
        {
          kind: 'p',
          text: 'What Suskii is responsible for. Running the app with reasonable care, keeping an accurate record of each job, and handling reports fairly. Providers are responsible for the errands they do, and customers for what they ask for, the information they give and paying for completed work.',
        },
        {
          kind: 'p',
          text: 'Limits. As far as the law allows, Suskii is not liable for indirect losses, for what customers and providers do, for payments made between them, or for loss of or damage to goods during an errand. Nothing in these terms limits liability for death or personal injury caused by our negligence, for fraud, or for anything else the law does not allow us to limit.',
        },
        {
          kind: 'p',
          text: 'The app as it is. We work to keep Suskii available but cannot promise it will always be free of errors or interruptions, especially where networks are unreliable.',
        },
        {
          kind: 'p',
          text: 'Governing law. These terms are governed by the laws of the Federal Republic of Nigeria, and the Nigerian courts decide disputes about them.',
        },
        {
          kind: 'p',
          text: 'Contact. support@suskiierrand.com for help with the app and these terms; privacy@suskiierrand.com for your personal data.',
        },
      ],
    },
  ],
};
