import 'package:flutter/material.dart';
import 'package:suskii_domain/suskii_domain.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

String meetupTopicLabel(AppLocalizations l10n, MeetupTopic topic) =>
    switch (topic) {
      MeetupTopic.social => l10n.meetTopicSocial,
      MeetupTopic.sportsFitness => l10n.meetTopicSports,
      MeetupTopic.businessNetworking => l10n.meetTopicBusiness,
      MeetupTopic.learning => l10n.meetTopicLearning,
      MeetupTopic.faith => l10n.meetTopicFaith,
      MeetupTopic.artsCulture => l10n.meetTopicArts,
      MeetupTopic.foodDrink => l10n.meetTopicFood,
      MeetupTopic.outdoors => l10n.meetTopicOutdoors,
      MeetupTopic.other => l10n.meetTopicOther,
    };

IconData meetupTopicIcon(MeetupTopic topic) => switch (topic) {
  MeetupTopic.social => Icons.celebration_outlined,
  MeetupTopic.sportsFitness => Icons.directions_run_rounded,
  MeetupTopic.businessNetworking => Icons.handshake_outlined,
  MeetupTopic.learning => Icons.menu_book_outlined,
  MeetupTopic.faith => Icons.volunteer_activism_outlined,
  MeetupTopic.artsCulture => Icons.palette_outlined,
  MeetupTopic.foodDrink => Icons.restaurant_outlined,
  MeetupTopic.outdoors => Icons.park_outlined,
  MeetupTopic.other => Icons.groups_outlined,
};

/// "Sat 14 Nov, 10:00": the start in the device's time zone.
String meetupWhen(BuildContext context, DateTime when) {
  final local = when.toLocal();
  final m = MaterialLocalizations.of(context);
  return '${m.formatMediumDate(local)}, '
      '${m.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}
