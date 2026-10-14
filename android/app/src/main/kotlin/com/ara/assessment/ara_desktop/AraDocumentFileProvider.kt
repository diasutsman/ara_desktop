package com.ara.assessment.ara_desktop

import androidx.core.content.FileProvider

/**
 * Dedicated FileProvider subclass for documents downloaded from the ARA portal.
 * A unique class name avoids manifest-merge clashes with providers declared by plugins
 * (e.g. flutter_inappwebview) that use androidx.core.content.FileProvider directly.
 */
class AraDocumentFileProvider : FileProvider()
