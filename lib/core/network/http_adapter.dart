import 'package:dio/dio.dart';

import 'http_adapter_io.dart' if (dart.library.js_interop) 'http_adapter_web.dart' as impl;

void configureDioAdapter(Dio dio) => impl.configureDioAdapter(dio);
