import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/html_artifact.dart';

void main() {
  test('Android render fixture is the production sandbox wrapper', () {
    final artifact = HtmlArtifact.create('owner', {
      'html': '<button id="count">0</button>',
      'css': 'button{color:rgb(255,0,0)}',
      'javascript':
          "const b=document.getElementById('count');b.onclick=()=>b.textContent=String(Number(b.textContent)+1);b.click();setInterval(()=>parent.postMessage({counter:b.textContent,css:getComputedStyle(b).color,bridge:typeof Ovid,rtc:typeof RTCPeerConnection},'*'),50);",
    });
    expect(
      File(
        'android/app/src/androidTest/assets/html_artifact_counter.html',
      ).readAsStringSync().trim(),
      artifact.sandboxDocument,
    );
  });
}
