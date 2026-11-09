const int linkNestProtocolVersion = 4;

const List<String> linkNestCapabilities = [
  'spaceTokenAuth',
  'multiUpload',
  'thumbnail',
  'preview',
  'originalDownload',
  'mediaMetadataV1',
  'livePhotoV1',
  'spaceIdentityV1',
  'videoRangeV1',
  'uploaderIdentityV1',
];

/// Guest MVP 依赖的协议能力。握手缺少任一项时，不进入后续写操作。
const List<String> guestRequiredCapabilities = [
  'spaceTokenAuth',
  'multiUpload',
  'thumbnail',
  'preview',
  'originalDownload',
  'mediaMetadataV1',
  'livePhotoV1',
  'spaceIdentityV1',
];
