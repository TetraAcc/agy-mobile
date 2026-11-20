import 'package:flutter_test/flutter_test.dart';
import 'package:agy_remote/main.dart';

void main() {
  testWidgets('Smoke test', (WidgetTester tester) async {
    expect(kAllOfficialModels.isNotEmpty, true);
  });
}
