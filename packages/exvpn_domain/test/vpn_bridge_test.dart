import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:test/test.dart';

void main() {
  test('application policy snapshots IDs and disabled preserves selection', () {
    final source = {'app.one'};
    final policy = ApplicationRoutingPolicy(
      mode: ApplicationRoutingMode.disabled,
      applicationIds: source,
    );
    source.add('app.two');
    expect(policy.applicationIds, {'app.one'});
    expect(
      () => policy.applicationIds.add('app.changed'),
      throwsUnsupportedError,
    );
    expect(policy.mode, ApplicationRoutingMode.disabled);
  });

  test(
    'application policy equality includes mode and ignores selection order',
    () {
      final a = ApplicationRoutingPolicy(
        mode: ApplicationRoutingMode.include,
        applicationIds: {'a', 'b'},
      );
      final b = ApplicationRoutingPolicy(
        mode: ApplicationRoutingMode.include,
        applicationIds: {'b', 'a'},
      );
      final excluded = ApplicationRoutingPolicy(
        mode: ApplicationRoutingMode.exclude,
        applicationIds: {'a', 'b'},
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(excluded));
    },
  );
}
