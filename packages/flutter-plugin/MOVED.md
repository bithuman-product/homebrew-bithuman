# The Flutter plugin moved

The bitHuman Flutter plugin (pub.dev package `bithuman`) now lives in its own project:

**https://gitlab.com/bithuman/sdk/bithuman-flutter**

- **New apps:** depend on `bithuman: ^3.0.0` from [pub.dev](https://pub.dev/packages/bithuman).
  There is no git dependency for 3.x.
- **Apps on 2.6.x** keep their git dependency unchanged: `url:
  https://github.com/bithuman-product/homebrew-bithuman.git`, `path: packages/flutter-plugin`,
  `ref: flutter-plugin-v2.6.<n>`. That GitHub copy stays readable with every `flutter-plugin-v*`
  tag, also once it is archived. 2.6.x gets critical fixes only: each one is tagged
  `flutter-plugin-v2.6.<n>` both on the GitHub copy and in the new project, so an app bumps only
  `ref:`. New features ship in 3.x.
- **History:** every commit and every `flutter-plugin-v*` tag of this directory is in the new
  project (same tag names, rewritten to the split history). The tags also stay here.
- **Issues and merge requests:** https://gitlab.com/bithuman/sdk/bithuman-flutter/-/issues

Docs: https://docs.bithuman.ai/platforms/flutter
