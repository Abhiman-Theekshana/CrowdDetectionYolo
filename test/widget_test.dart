import 'package:flutter_test/flutter_test.dart';
import 'package:buzing_crowd_detection/main.dart';

void main() {
  testWidgets('App launches correctly', (WidgetTester tester) async {
    await tester.pumpWidget(const BuzingApp());
    expect(find.text('Buzing.lk'), findsOneWidget);
  });
}
