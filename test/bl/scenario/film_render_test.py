"""Offline contract + actual media smoke. No provider or browser required."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('film', ROOT/'priv/lib/scenario/film/render.py')
film = importlib.util.module_from_spec(spec)
spec.loader.exec_module(film)


class FilmTest(unittest.TestCase):
    def test_subtitle_covers_measured_speech_even_when_visual_hint_is_short(self):
        for audio in [.001, 1.017, 10.333, 62.811]:
            t = film.schedule({'duration': .1, 'lead': .7, 'tail': 0}, audio, 30)
            self.assertLessEqual(t['subtitle_start'], t['audio_start'])
            self.assertGreaterEqual(t['subtitle_end'], t['audio_end'] + .25)
            self.assertGreaterEqual(t['duration'], .7 + audio + .25)
            self.assertAlmostEqual(round(t['duration']*30), t['duration']*30)

    def test_camera_clamps_before_first_key_and_eases_between_keys(self):
        points = [{'at': 1, 'x': .2}, {'at': 3, 'x': .8}]
        self.assertEqual(.2, film.interpolate(points, 'x', 0, .5))
        self.assertAlmostEqual(.5, film.interpolate(points, 'x', 2, .5))
        self.assertEqual(.8, film.interpolate(points, 'x', 4, .5))

    def test_rejects_duplicate_ids_nonfinite_timing_and_inverted_keys(self):
        scene = {'id': 'a', 'source': 'a.png', 'say': 'Bonjour'}
        for scenes in [[scene, scene], [{**scene, 'duration': float('nan')}],
                       [{**scene, 'camera': [{'at': 2}, {'at': 1}]}]]:
            with self.assertRaises(ValueError):
                film.validate({'version': 1, 'id': 'demo', 'scenes': scenes})

    def test_real_two_scene_export_keeps_audio_cues_and_video_frames(self):
        with tempfile.TemporaryDirectory(prefix='film smoke ') as folder:
            root = Path(folder)
            source, audio = root/'source.png', root/'voice.wav'
            film.run(['ffmpeg','-loglevel','error','-y','-f','lavfi','-i','color=c=white:s=640x480','-frames:v','1','-threads','1',source])
            film.run(['ffmpeg','-loglevel','error','-y','-f','lavfi','-i','sine=frequency=440:duration=1.017','-ar','48000',audio])
            scene = {'id':'first','source':str(source),'audio':str(audio), 'say':'Un écran clair. Une décision simple.',
                     'camera':[{'at':0,'zoom':1},{'at':1,'zoom':1.3,'x':.7}],
                     'cursor':[{'at':0,'x':.2,'y':.4},{'at':.6,'x':.7,'y':.5,'click':True}]}
            value = {'version':1,'id':'smoke','width':640,'height':480,'fps':10,
                     'run':{'verdict':'unknown'}, 'scenes':[scene,{**scene,'id':'second','source_start':0}]}
            result = film.export(value, root/'out')
            self.assertEqual('unknown', result['run']['verdict'])
            self.assertEqual(2, len(result['scenes']))
            info = film.probe(root/'out/demo.mp4')
            self.assertEqual(['video','audio','subtitle'], [s['codec_type'] for s in info['streams'][:3]])
            for row in result['scenes']:
                self.assertGreaterEqual(row['subtitle_end'], row['audio_end'])
            self.assertLess(abs(result['encoded_duration']-result['duration']), .1)
            self.assertEqual(2, (root/'out/subtitles.srt').read_text().count('-->'))
            self.assertTrue((root/'out/subtitles.vtt').read_text().startswith('WEBVTT'))


if __name__ == '__main__':
    unittest.main()
