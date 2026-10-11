#!/usr/bin/env python3
"""Optional scenario.film media worker. Python stdlib + explicit media tools.

The JSON edit is immutable input. The manifest records measured audio, source
hashes, subtitle intervals and output durations. Nothing imports a browser or
contacts a provider until export is explicitly requested.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import textwrap
import urllib.error
import urllib.parse
import urllib.request


def run(args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f"{args[0]} failed: {result.stderr[-2400:]}")
    return result.stdout


def probe(path):
    return json.loads(run(['ffprobe', '-v', 'error', '-show_format', '-show_streams',
                           '-of', 'json', path]))


def duration(path):
    value = float(probe(path)['format']['duration'])
    if not math.isfinite(value) or value <= 0:
        raise ValueError('Media must have a finite positive duration')
    return value


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for part in iter(lambda: f.read(1024 * 1024), b''):
            h.update(part)
    return h.hexdigest()


def load_env(path):
    # A dotenv file is data, never shell code. Do not replace caller env values.
    if path:
        for line in Path(path).read_text().splitlines():
            match = re.fullmatch(r'\s*(?:export\s+)?([A-Za-z_][A-Za-z_0-9]*)\s*=\s*(.*?)\s*', line)
            if match:
                os.environ.setdefault(match[1], match[2].strip('\"\''))


def finite(value, label, low=0, high=86400):
    if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or not low <= value <= high:
        raise ValueError(f'Invalid {label}')
    return value


def validate(value):
    if value.get('version') != 1 or not value.get('id'):
        raise ValueError('Film requires version 1 and an id')
    if not value.get('scenes'):
        raise ValueError('Film requires scenes')
    for k, default, lo, hi in [('width', 1920, 640, 3840), ('height', 1080, 480, 2160), ('fps', 30, 1, 60)]:
        n = finite(value.get(k, default), k, lo, hi)
        if int(n) != n or (k != 'fps' and n % 2):
            raise ValueError(f'{k} must be an even integer' if k != 'fps' else 'fps must be an integer')
    ids = set()
    for scene in value['scenes']:
        if not isinstance(scene.get('id'), str) or scene['id'] in ids:
            raise ValueError('Scene ids must be unique strings')
        ids.add(scene['id'])
        if not scene.get('source'):
            raise ValueError('Every scene requires a local source')
        if not scene.get('say') and not scene.get('audio'):
            raise ValueError('Every scene requires narration text or a local audio file')
        for key in ['lead', 'tail', 'duration', 'source_start']:
            if key in scene:
                finite(scene[key], key)
        finite(scene.get('speed', 1), 'speed', .1, 8)
        for track in ['camera', 'cursor']:
            last = -1
            for point in scene.get(track, []):
                t = finite(point['at'], 'keyframe time')
                if t <= last:
                    raise ValueError('Keyframe times must increase strictly')
                last = t
                for axis in ['x', 'y']:
                    finite(point.get(axis, .5), axis, 0, 1)
                if track == 'camera':
                    finite(point.get('zoom', 1), 'zoom', 1, 4)
    return value


def speech(text, voice, path):
    if path.exists():
        duration(path)  # A truncated cache entry is never trusted.
        return
    key = os.environ.get('DEEPGRAM_API_KEY')
    if not key:
        raise ValueError('Set DEEPGRAM_API_KEY or provide local scene audio')
    query = urllib.parse.urlencode({'model': voice, 'encoding': 'linear16',
                                   'container': 'wav', 'sample_rate': 48000})
    request = urllib.request.Request('https://api.deepgram.com/v1/speak?' + query,
        data=json.dumps({'text': text}).encode(),
        headers={'Authorization': 'Token ' + key, 'Content-Type': 'application/json'})
    temp = path.with_suffix('.pending')
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            temp.write_bytes(response.read())
        duration(temp)
        temp.replace(path)
    except urllib.error.HTTPError as error:
        # Provider bodies and request headers may contain sensitive context.
        raise ValueError(f'Deepgram speech request failed (HTTP {error.code})') from None
    finally:
        temp.unlink(missing_ok=True)


def schedule(scene, audio_duration, fps):
    lead, tail = scene.get('lead', .35), max(scene.get('tail', .55), .25)
    # Round UP to a video frame; a caller's short duration never truncates voice.
    length = math.ceil(max(scene.get('duration', 0), lead + audio_duration + tail) * fps) / fps
    return {'duration': length, 'audio_start': lead, 'audio_end': lead + audio_duration,
            'subtitle_start': 0, 'subtitle_end': length, 'audio_duration': audio_duration}


def timestamp(seconds, vtt=False):
    ms = round(seconds * 1000)
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return f'{h:02}:{m:02}:{s:02}{"." if vtt else ","}{ms:03}'


def subtitles(rows, path, vtt=False):
    parts = ['WEBVTT\n'] if vtt else []
    for i, row in enumerate(rows, 1):
        start, end, text = row
        parts.append(f'{i}\n{timestamp(start,vtt)} --> {timestamp(end,vtt)}\n{text}\n')
    Path(path).write_text('\n'.join(parts), encoding='utf-8')


def interpolate(points, field, t, default):
    if not points:
        return default
    previous = points[0]
    for point in points[1:]:
        if t < point['at']:
            u = max(0, min(1, (t - previous['at']) / (point['at'] - previous['at'])))
            u = u * u * (3 - 2 * u)
            return previous.get(field, default) + (point.get(field, default) - previous.get(field, default)) * u
        previous = point
    return previous.get(field, default)


def expression(points, field, clock, default):
    if not points:
        return str(default)
    result = str(points[-1].get(field, default))
    for a, b in reversed(list(zip(points, points[1:]))):
        u = f'clip(({clock}-{a["at"]})/{b["at"]-a["at"]},0,1)'
        ease = f'({u})*({u})*(3-2*({u}))'
        start, end = a.get(field, default), b.get(field, default)
        result = f'if(lt({clock},{b["at"]}),{start}+({end-start})*({ease}),{result})'
    return result


def filter_path(path):
    # FFmpeg filtergraph escaping is separate from shell quoting. We use argv.
    return str(Path(path).resolve()).replace('\\', '\\\\').replace(':', '\\:').replace("'", "'\\''")


def cursor_assets(folder):
    paths = []
    shapes = [
        '<path d="M5 4 L5 43 L15 33 L24 53 L33 49 L24 30 L39 30 Z" fill="white" stroke="#2b2824" stroke-width="2.5" stroke-linejoin="round"/>',
        '<circle cx="40" cy="40" r="27" fill="none" stroke="#b5451f" stroke-width="4"/><circle cx="40" cy="40" r="11" fill="#b5451f" fill-opacity=".20"/>']
    for name, shape in zip(['cursor', 'click'], shapes):
        svg, png = folder / f'{name}.svg', folder / f'{name}.png'
        svg.write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="80" height="80">{shape}</svg>')
        run(['rsvg-convert', '-o', png, svg])
        paths.append(png)
    return paths


def render_scene(scene, timing, audio, work, film):
    w, h, fps = film.get('width', 1920), film.get('height', 1080), film.get('fps', 30)
    top, bottom = round(h * .073), round(h * .132)
    stage = h - top - bottom
    stage -= stage % 2
    bg = film.get('background', '#f7f4ee')
    source = Path(scene['source']).resolve()
    info = probe(source)
    stream = next(s for s in info['streams'] if s['codec_type'] == 'video')
    sw, sh = stream['width'], stream['height']
    scale = min(w / sw, stage / sh)
    fitw, fith = sw * scale, sh * scale
    ox, oy = (w - fitw) / 2, (stage - fith) / 2
    is_image = source.suffix.lower() in ['.png', '.jpg', '.jpeg', '.webp']
    inputs = ['-loop', '1', '-framerate', str(fps)] if is_image else ['-ss', str(scene.get('source_start', 0))]
    args = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-threads', '2', *inputs, '-i', source, '-i', audio]
    cursor = scene.get('cursor', [])
    if cursor:
        for asset in cursor_assets(work):
            args += ['-loop', '1', '-framerate', str(fps), '-i', asset]
    camera = scene.get('camera', [])
    z = expression(camera, 'zoom', f'on/{fps}', 1)
    cx = expression(camera, 'x', f'on/{fps}', .5)
    cy = expression(camera, 'y', f'on/{fps}', .5)
    # The camera/cursor are authored in normalized SOURCE coordinates, before
    # contain-fit padding. The same projection drives both, including clamps.
    left = f'max(0,min(iw-iw/zoom,{ox}+{fitw}*({cx})-iw/zoom/2))'
    upper = f'max(0,min(ih-ih/zoom,{oy}+{fith}*({cy})-ih/zoom/2))'
    speed = scene.get('speed', 1)
    filters = [f'[0:v]setpts=(PTS-STARTPTS)/{speed},fps={fps},scale={w}:{stage}:force_original_aspect_ratio=decrease,pad={w}:{stage}:(ow-iw)/2:(oh-ih)/2:color={bg},tpad=stop_mode=clone:stop_duration={timing["duration"]},zoompan=z=\'{z}\':x=\'{left}\':y=\'{upper}\':d=1:s={w}x{stage}:fps={fps},pad={w}:{h}:0:{top}:color={bg}[base]']
    current = 'base'
    if cursor:
        zt = expression(camera, 'zoom', 't', 1)
        cxt, cyt = expression(camera, 'x', 't', .5), expression(camera, 'y', 't', .5)
        xt, yt = expression(cursor, 'x', 't', .5), expression(cursor, 'y', 't', .5)
        lx = f'max(0,min({w}-{w}/({zt}),{ox}+{fitw}*({cxt})-{w}/({zt})/2))'
        ly = f'max(0,min({stage}-{stage}/({zt}),{oy}+{fith}*({cyt})-{stage}/({zt})/2))'
        px = f'(({ox}+{fitw}*({xt})-({lx}))*({zt}))'
        py = f'({top}+({oy}+{fith}*({yt})-({ly}))*({zt}))'
        clicks = [p['at'] for p in cursor if p.get('click')]
        enabled = '+'.join(f'between(t,{t},{t+.38})' for t in clicks) or '0'
        filters += [f'[base][3:v]overlay=x=\'{px}-40\':y=\'{py}-40\':enable=\'{enabled}\'[ring]',
                    f'[ring][2:v]overlay=x=\'{px}-5\':y=\'{py}-4\'[pointer]']
        current = 'pointer'
    title = work / 'title.txt'
    title.write_text(scene.get('title', film.get('title', film['id'])), encoding='utf-8')
    label = work / 'label.txt'
    label.write_text(film.get('label', ''), encoding='utf-8')
    caption = work / 'caption.ass'
    # Limit line width, preserving punctuation and French accents. No word
    # disappears early: the COMPLETE cue covers the COMPLETE audio interval.
    text = scene.get('subtitle', scene.get('say', ''))
    wrapped = '\n'.join(textwrap.wrap(text, width=70))
    if len(wrapped.splitlines()) > 2:
        raise ValueError('Narration passage is too long: split it into scenes (two subtitle lines maximum)')
    fs = max(18, round(h * .031))
    safe_text = wrapped.replace('\\', '\\e').replace('{', '\\{').replace('}', '\\}').replace('\n', '\\N')
    end = timestamp(timing['subtitle_end'], True)[1:-1]
    caption.write_text(f'''[Script Info]
ScriptType: v4.00+
PlayResX: {w}
PlayResY: {h}
WrapStyle: 2
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,DejaVu Sans,{fs},&H0024282B,&H0024282B,&H00F4F7FA,&H00F4F7FA,0,0,0,0,100,100,0,0,1,0,0,2,40,40,{round(h*.032)},1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,{end},Default,,0,0,0,,{safe_text}
''', encoding='utf-8')
    filters.append(f'[{current}]drawtext=textfile=\'{filter_path(title)}\':expansion=none:fontcolor=#2b2824:fontsize={round(h*.025)}:x=48:y=25,drawtext=textfile=\'{filter_path(label)}\':expansion=none:fontcolor=#635b51:fontsize={round(h*.016)}:x=w-tw-48:y=30,ass=filename=\'{filter_path(caption)}\',format=yuv420p[v]')
    filters.append(f'[1:a]adelay={round(timing["audio_start"]*1000)}:all=1,apad,atrim=duration={timing["duration"]},asetpts=PTS-STARTPTS[a]')
    script = work / 'filters.txt'
    script.write_text(';\n'.join(filters))
    output = work / 'scene.mkv'
    args += ['-filter_complex_threads', '1', '-filter_complex', script.read_text(), '-map', '[v]', '-map', '[a]',
             '-t', str(timing['duration']), '-r', str(fps), '-c:v', 'libx264', '-preset', 'fast', '-crf', '19',
             '-threads', '2', '-c:a', 'pcm_s16le', '-ar', '48000', '-ac', '2', output]
    run(args)
    return output


def export(film, out):
    validate(film)
    out = Path(out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    cache = out / 'speech'
    cache.mkdir(exist_ok=True)
    voice = film.get('voice', 'aura-2-hector-fr')
    fps = film.get('fps', 30)
    scenes, cues, offset, clips = [], [], 0, []
    for index, authored in enumerate(film['scenes']):
        scene = dict(authored)
        source = Path(scene['source']).resolve()
        if not source.is_file():
            raise ValueError(f'Missing source for scene {scene["id"]}')
        if scene.get('audio'):
            audio = Path(scene['audio']).resolve()
            provider = 'local'
        else:
            key = hashlib.sha256(json.dumps([voice, scene['say'], 48000]).encode()).hexdigest()
            audio = cache / (key + '.wav')
            speech(scene['say'], voice, audio)
            provider = 'deepgram'
        timing = schedule(scene, duration(audio), fps)
        work = out / 'work' / f'{index:03}'
        work.mkdir(parents=True, exist_ok=True)
        clips.append(render_scene(scene, timing, audio, work, film))
        record = {**scene, **timing, 'offset': offset, 'source': str(source), 'source_sha256': digest(source),
                  'audio': str(audio), 'audio_sha256': digest(audio), 'provider': provider}
        scenes.append(record)
        cues.append((offset + timing['subtitle_start'], offset + timing['subtitle_end'], scene.get('subtitle', scene.get('say', ''))))
        offset += timing['duration']
        print(f'Encoded scene {index+1}/{len(film["scenes"])}: {scene["id"]}', flush=True)
    subtitles(cues, out / 'subtitles.srt')
    subtitles(cues, out / 'subtitles.vtt', True)
    metadata = [';FFMETADATA1', 'title=' + film.get('title', film['id'])]
    for scene in scenes:
        clean_title = scene.get('title', scene['id']).replace('\\', '\\\\').replace('=', '\\=').replace(';', '\\;').replace('#', '\\#').replace('\n', ' ')
        metadata += ['[CHAPTER]', 'TIMEBASE=1/1000', f'START={round(scene["offset"]*1000)}',
                     f'END={round((scene["offset"]+scene["duration"])*1000)}', 'title=' + clean_title]
    chapter_file = out / 'chapters.ffmetadata'
    chapter_file.write_text('\n'.join(metadata))
    # Each temporary path is generated, but apostrophes in the output root are
    # still escaped for the concat demuxer's own grammar (no shell is involved).
    concat = out / 'work' / 'concat.txt'
    concat.write_text('\n'.join("file '" + str(p).replace("'", "'\\''") + "'" for p in clips))
    movie = out / 'demo.mp4'
    run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', concat,
         '-i', chapter_file, '-i', out/'subtitles.srt', '-map', '0:v', '-map', '0:a', '-map', '2:0',
         '-map_metadata', '1', '-map_chapters', '1', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '160k', '-c:s', 'mov_text',
         '-metadata:s:s:0', 'language='+film.get('language', 'fr'), '-movflags', '+faststart', movie])
    actual = duration(movie)
    if actual + 1/fps < offset:
        raise ValueError('Export ended before the narration timeline')
    manifest = {'version': 1, 'id': film['id'], 'voice': voice, 'language': film.get('language','fr'),
                'duration': offset, 'encoded_duration': actual, 'scenes': scenes,
                'run': film.get('run'), 'video': str(movie), 'video_sha256': digest(movie),
                'subtitles': {'burned_in': True, 'track': True, 'srt': str(out/'subtitles.srt'), 'vtt': str(out/'subtitles.vtt')},
                'tools': {'ffmpeg': run(['ffmpeg','-version']).splitlines()[0]},
                'timing_policy': 'complete cue covers measured audio plus lead and reading tail'}
    (out / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('film')
    parser.add_argument('--out', required=True)
    parser.add_argument('--env-file')
    args = parser.parse_args()
    load_env(args.env_file)
    export(json.loads(Path(args.film).read_text()), args.out)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
