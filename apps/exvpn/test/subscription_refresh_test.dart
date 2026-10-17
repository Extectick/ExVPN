import 'dart:async';

import 'package:exvpn/services/subscription_loader.dart';
import 'package:exvpn/services/subscription_refresh.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const oldProfile =
    'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#Old';
const newProfile =
    'vless://00000000-0000-4000-8000-000000000002@sample.invalid:443?security=tls#New';
void main() {
  test(
    'restart reservation discards a late HTTP response before storage changes',
    () async {
      final app = AppController()
        ..addSubscription(
          name: 'Example',
          raw: oldProfile,
          sourceUrl: 'https://example.invalid/sub',
        );
      var allowed = true;
      final response = Completer<http.Response>();
      var requests = 0;
      final refresh = SubscriptionRefresh(
        app,
        canApply: () => allowed,
        loader: SubscriptionLoader(
          client: MockClient((_) {
            requests++;
            return response.future;
          }),
        ),
      );
      addTearDown(refresh.dispose);
      addTearDown(app.dispose);
      var changes = 0;
      final listener = app.changes.listen((_) => changes++);
      addTearDown(listener.cancel);
      final pending = refresh.refresh(app.groups.single.id);
      allowed = false;
      final before = changes;
      response.complete(http.Response(newProfile, 200));
      expect(await pending, isFalse);
      expect(app.selectedServer!.name, 'Old');
      expect(changes, before);
      expect(refresh.failed, isEmpty);
      expect(await refresh.refresh(app.groups.single.id), isFalse);
      expect(requests, 1);
    },
  );

  test(
    'background partial refresh retains the working list until confirmation',
    () async {
      final app = AppController()
        ..addSubscription(
          name: 'Example',
          raw: oldProfile,
          sourceUrl: 'https://example.invalid/sub',
        );
      final refresh = SubscriptionRefresh(
        app,
        loader: SubscriptionLoader(
          client: MockClient(
            (_) async => http.Response('$newProfile\nunknown://invalid', 200),
          ),
        ),
      );
      addTearDown(refresh.dispose);
      addTearDown(app.dispose);
      final id = app.groups.single.id;
      final before = app.groups.single.updatedAt!;
      await refresh.refreshStale(now: before.add(const Duration(hours: 7)));
      expect(app.selectedServer!.name, 'Old');
      expect(app.groups.single.updatedAt, before);
      expect(refresh.failed, {id});
      expect(app.acceptPartialUpdate(app.pendingUpdate(id)!), isTrue);
      expect(app.selectedServer!.name, 'New');
      expect(refresh.failed, isEmpty);
    },
  );

  test(
    'a newer download invalidates old consent before the HTTP outcome',
    () async {
      final app = AppController()
        ..addSubscription(
          name: 'Example',
          raw: oldProfile,
          sourceUrl: 'https://example.invalid/sub',
        );
      final id = app.groups.single.id;
      app.updateSubscription(
        groupId: id,
        raw: '$newProfile\nunknown://invalid',
      );
      final oldCandidate = app.pendingUpdate(id)!;
      final response = Completer<http.Response>();
      final refresh = SubscriptionRefresh(
        app,
        loader: SubscriptionLoader(client: MockClient((_) => response.future)),
      );
      addTearDown(refresh.dispose);
      addTearDown(app.dispose);
      final request = refresh.refresh(id);
      expect(app.pendingUpdate(id), isNull);
      expect(app.acceptPartialUpdate(oldCandidate), isFalse);
      response.complete(http.Response('', 503));
      expect(await request, isFalse);
      expect(app.selectedServer!.name, 'Old');
      expect(app.pendingUpdate(id), isNull);
    },
  );

  test(
    'late HTTP response cannot overwrite an accepted partial replacement',
    () async {
      final app = AppController()
        ..addSubscription(
          name: 'Example',
          raw: oldProfile,
          sourceUrl: 'https://example.invalid/sub',
        );
      final id = app.groups.single.id;
      final response = Completer<http.Response>();
      final refresh = SubscriptionRefresh(
        app,
        loader: SubscriptionLoader(client: MockClient((_) => response.future)),
      );
      addTearDown(refresh.dispose);
      addTearDown(app.dispose);
      final request = refresh.refresh(id);
      app.updateSubscription(
        groupId: id,
        raw: '$newProfile\nunknown://invalid',
      );
      expect(app.acceptPartialUpdate(app.pendingUpdate(id)!), isTrue);
      response.complete(http.Response(oldProfile, 200));
      expect(await request, isFalse);
      expect(app.selectedServer!.name, 'New');
    },
  );

  test(
    'HWID limit preserves the last working list and a safe reason',
    () async {
      final app = AppController()
        ..addSubscription(
          name: 'Example',
          raw: oldProfile,
          sourceUrl: 'https://example.invalid/sub',
        );
      var limited = true;
      final refresh = SubscriptionRefresh(
        app,
        loader: SubscriptionLoader(
          client: MockClient(
            (_) async => limited
                ? http.Response(
                    newProfile,
                    200,
                    headers: {'x-hwid-max-devices-reached': 'true'},
                  )
                : http.Response(newProfile, 200),
          ),
        ),
      );
      addTearDown(refresh.dispose);
      addTearDown(app.dispose);
      final id = app.groups.single.id;
      expect(await refresh.refresh(id), isFalse);
      expect(app.selectedServer!.name, 'Old');
      expect(
        refresh.errorCode(id),
        SubscriptionLoadErrorCode.deviceLimitReached,
      );
      limited = false;
      expect(await refresh.refresh(id), isTrue);
      expect(app.selectedServer!.name, 'New');
      expect(refresh.errorCode(id), isNull);
    },
  );
  test(
    'coalesces concurrent refresh and retains working profiles on corrupt data',
    () async {
      final app = AppController()
        ..addSubscription(
          name: 'Example',
          raw: oldProfile,
          sourceUrl: 'https://example.invalid/sub',
        );
      final response = Completer<http.Response>();
      var requests = 0;
      final refresh = SubscriptionRefresh(
        app,
        loader: SubscriptionLoader(
          client: MockClient((_) {
            requests++;
            return response.future;
          }),
        ),
      );
      final id = app.groups.single.id;
      final first = refresh.refresh(id);
      final second = refresh.refresh(id);
      response.complete(http.Response('bad://invalid', 200));
      expect(await first, false);
      expect(await second, false);
      expect(requests, 1);
      expect(app.selectedServer!.name, 'Old');
      expect(refresh.failed, {id});
      refresh.dispose();
      app.dispose();
    },
  );
  test(
    'late automatic response cannot overwrite manually replaced subscription',
    () async {
      final app = AppController()
        ..addSubscription(
          name: 'Example',
          raw: oldProfile,
          sourceUrl: 'https://example.invalid/sub',
        );
      final response = Completer<http.Response>();
      final refresh = SubscriptionRefresh(
        app,
        loader: SubscriptionLoader(client: MockClient((_) => response.future)),
      );
      final id = app.groups.single.id;
      final pending = refresh.refresh(id);
      app.updateSubscription(
        groupId: id,
        raw: newProfile,
        clearSourceUrl: true,
      );
      response.complete(http.Response(oldProfile, 200));
      expect(await pending, false);
      expect(app.selectedServer!.name, 'New');
      expect(app.groups.single.sourceUrl, isNull);
      refresh.dispose();
      app.dispose();
    },
  );
  test(
    'startup refresh only fetches URL subscriptions older than six hours',
    () async {
      final app = AppController()
        ..addSubscription(
          name: 'Example',
          raw: oldProfile,
          sourceUrl: 'https://example.invalid/sub',
        );
      var requests = 0;
      final refresh = SubscriptionRefresh(
        app,
        loader: SubscriptionLoader(
          client: MockClient((_) async {
            requests++;
            return http.Response(newProfile, 200);
          }),
        ),
      );
      final updated = app.groups.single.updatedAt!;
      await refresh.refreshStale(now: updated.add(const Duration(hours: 5)));
      expect(requests, 0);
      await refresh.refreshStale(now: updated.add(const Duration(hours: 6)));
      expect(requests, 1);
      expect(app.selectedServer!.name, 'New');
      refresh.dispose();
      app.dispose();
    },
  );

  test(
    'manual same-source update wins and an obsolete error is discarded',
    () async {
      final app = AppController()
        ..addSubscription(
          name: 'Example',
          raw: oldProfile,
          sourceUrl: 'https://example.invalid/sub',
        );
      final response = Completer<http.Response>();
      final refresh = SubscriptionRefresh(
        app,
        loader: SubscriptionLoader(client: MockClient((_) => response.future)),
      );
      final id = app.groups.single.id;
      final pending = refresh.refresh(id);
      app.updateSubscription(groupId: id, raw: newProfile);
      response.complete(http.Response('', 503));
      expect(await pending, false);
      expect(app.selectedServer!.name, 'New');
      expect(refresh.failed, isEmpty);
      refresh.dispose();
      app.dispose();
    },
  );

  test(
    'manual recovery clears a failure but collapsing the group does not',
    () async {
      final app = AppController()
        ..addSubscription(
          name: 'Example',
          raw: oldProfile,
          sourceUrl: 'https://example.invalid/sub',
        );
      final refresh = SubscriptionRefresh(
        app,
        loader: SubscriptionLoader(
          client: MockClient((_) async => http.Response('', 503)),
        ),
      );
      final id = app.groups.single.id;
      expect(await refresh.refresh(id), false);
      expect(refresh.failed, {id});
      app.toggleGroup(id);
      expect(refresh.failed, {id});
      app.updateSubscription(groupId: id, raw: newProfile);
      expect(refresh.failed, isEmpty);
      refresh.dispose();
      app.dispose();
    },
  );

  test(
    'group presentation changes do not cancel an in-flight refresh',
    () async {
      final app = AppController()
        ..addSubscription(
          name: 'Example',
          raw: oldProfile,
          sourceUrl: 'https://example.invalid/sub',
        );
      final response = Completer<http.Response>();
      final refresh = SubscriptionRefresh(
        app,
        loader: SubscriptionLoader(client: MockClient((_) => response.future)),
      );
      final id = app.groups.single.id;
      final pending = refresh.refresh(id);
      app.toggleGroup(id);
      response.complete(http.Response(newProfile, 200));
      expect(await pending, true);
      expect(app.groups.single.expanded, false);
      expect(app.selectedServer!.name, 'New');
      refresh.dispose();
      app.dispose();
    },
  );
}
