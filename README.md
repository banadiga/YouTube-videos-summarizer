# YouTube-videos-summarizer

A tool to automate the extraction of YouTube video information and metadata for further processing (e.g., summarization). It downloads video metadata and stores the source URL in a structured workspace.

## Features

- Supports both individual YouTube video URLs and YouTube channel/playlist URLs.
- Automatically handles video metadata extraction using `yt-dlp`.
- Organizes output into a clear directory structure based on channel name and video titles.
- Saves a direct link to the source video in a `video.url` file for each processed entry.
- Skips already processed videos unless forced.

## Prerequisites

The following tools must be installed on your system:

- **yt-dlp**: For metadata extraction and video list retrieval.
- **jq**: For JSON processing of the metadata.
- **curl**: For interacting with the backend summarization service.
- **Homebrew** (on macOS): Recommended for easy dependency installation.

## Installation

You can use the provided `install.sh` script to install the tool and its dependencies:

```bash
chmod +x install.sh
./install.sh
```

This will:
1. Check for and install missing dependencies using Homebrew.
2. Install the `yt_process` script to `/usr/local/bin`.

## Usage

### Main Command: `yt_process`

After installation, use the `yt_process` command:

```bash
yt_process --workspace "<WORKSPACE_PATH>" --url "<YOUTUBE_URL>" [options]
```

**Required Arguments:**
- `--workspace`: Path to the directory where results will be stored.
- `--url`: A YouTube video URL, or a link to a channel/playlist.

**Optional Arguments:**
- `--max N`: Maximum number of videos to process.
- `--sleep-seconds S`: Time to wait between processing videos.
- `--force`: Reprocess videos even if metadata already exists.
- `--verbose`: Enable detailed logging.

## Workspace Structure

The tool organizes data in the specified workspace as follows:

```text
<WORKSPACE_PATH>/
└── <Channel_Name>/
    └── <VideoID>-<Sanitized_Title>/
        ├── response.json   # Processed result/summary
        └── video.url       # Direct link to the YouTube video
```

A `work` directory within the workspace is used for temporary files and run logs.
