import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 16, 12);
  final good = const SubscriptionParser().parse('hy2://password@node.example');
  final changed = const SubscriptionParser().parse(
    'hy2://password@new.example',
  );
  final failed = const SubscriptionParser().parse(
    'unsupported://private-value',
  );
  SubscriptionSnapshot saved() => SubscriptionSnapshot(
    id: 'local-subscription-id',
    profiles: good.profiles,
    lastSuccessfulRefresh: now,
    lastAttempt: now,
  );

  test('uninitialized subscription refreshes immediately', () {
    expect(
      SubscriptionSnapshot(id: 'new', profiles: []).needsRefresh(now),
      isTrue,
    );
  });

  test('six-hour expiry uses inclusive boundary', () {
    expect(saved().needsRefresh(now.add(const Duration(hours: 6))), isTrue);
    expect(
      saved().needsRefresh(
        now.add(const Duration(hours: 6) - const Duration(microseconds: 1)),
      ),
      isFalse,
    );
  });

  test('clock moving backwards cannot indefinitely suppress refresh', () {
    expect(
      saved().needsRefresh(now.subtract(const Duration(hours: 1))),
      isTrue,
    );
  });

  test('failed refresh preserves working list and successful timestamp', () {
    final attempt = now.add(const Duration(hours: 7));
    final next = saved().apply(failed, attempt);
    expect(next.profiles.single.id, good.profiles.single.id);
    expect(next.lastSuccessfulRefresh, now);
    expect(next.lastAttempt, attempt);
    expect(next.issues, failed.issues);
  });

  test('empty refresh does not erase working nodes', () {
    final next = saved().apply(
      const SubscriptionParser().parse('{"outbounds":[]}'),
      now.add(const Duration(hours: 1)),
    );
    expect(next.profiles, good.profiles);
    expect(next.issues.single.code, ImportIssueCode.empty);
  });

  test('partial failure does not silently replace existing working list', () {
    final partial = ImportResult(changed.profiles, failed.issues);
    final next = saved().apply(partial, now.add(const Duration(hours: 1)));
    expect(next.profiles, good.profiles);
    expect(next.lastSuccessfulRefresh, now);
    expect(next.issues, failed.issues);
  });

  test(
    'first import can show valid entries and warnings from partial input',
    () {
      final initial = SubscriptionSnapshot(id: 'new', profiles: []);
      final next = initial.apply(
        ImportResult(good.profiles, failed.issues),
        now,
      );
      expect(next.profiles, good.profiles);
      expect(next.issues, failed.issues);
    },
  );

  test('ignored local config notice does not block valid refresh', () {
    final next = saved().apply(
      ImportResult(changed.profiles, [
        const ImportIssue(0, ImportIssueCode.ignoredLocalConfiguration),
      ]),
      now.add(const Duration(hours: 1)),
    );
    expect(next.profiles, changed.profiles);
  });

  test(
    'successful refresh atomically replaces nodes and clears old errors',
    () {
      final attempt = now.add(const Duration(hours: 7));
      final next = saved()
          .apply(failed, attempt)
          .apply(changed, attempt.add(const Duration(minutes: 1)));
      expect(next.profiles, changed.profiles);
      expect(next.issues, isEmpty);
      expect(
        next.lastSuccessfulRefresh,
        attempt.add(const Duration(minutes: 1)),
      );
      expect(next.id, 'local-subscription-id');
    },
  );

  test('older completion cannot replace later success or later error', () {
    final later = now.add(const Duration(minutes: 3));
    final older = now.add(const Duration(minutes: 1));
    final success = saved().apply(changed, later);
    expect(success.apply(good, older), same(success));
    final error = saved().apply(failed, later);
    expect(error.apply(changed, older), same(error));
  });

  test('snapshot copies caller-owned lists', () {
    final profiles = good.profiles.toList();
    final issues = failed.issues.toList();
    final snapshot = SubscriptionSnapshot(
      id: 'copy',
      profiles: profiles,
      issues: issues,
    );
    profiles.clear();
    issues.clear();
    expect(snapshot.profiles, hasLength(1));
    expect(snapshot.issues, hasLength(1));
    expect(() => snapshot.profiles.clear(), throwsUnsupportedError);
    expect(() => snapshot.issues.clear(), throwsUnsupportedError);
  });
}
