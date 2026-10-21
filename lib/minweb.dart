import 'package:flutter/material.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/chat_page.dart';

void main() => runApp(MaterialApp(theme: OTheme.light(), home: const V2ChatPage(data: V2ChatPageData())));
