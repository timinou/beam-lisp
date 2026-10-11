"""Offline contract + actual media smoke. No provider or browser required."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('film', ROOT/'priv/lib/scenario/film/render.py')
film = importlib.util.module_from_spec(spec)
spec.loader.exec_module(film)


class FilmTest(unittest.TestCase):
    def test_malformed_credentials_never_reach_http_diagnostics(self):
        with tempfile.TemporaryDirectory() as root:
            with patch.dict('os.environ', {'DEEPGRAM_API_KEY':'private-token\nSECOND-PRIVATE-TOKEN'}):
                with self.assertRaises(ValueError) as result:
                    film.speech('Bonjour', 'aura-2-hector-fr', Path(root)/'voice.wav')
                self.assertNotIn('private-token', str(result.exception))
                self.assertNotIn('SECOND-PRIVATE-TOKEN', str(result.exception))

    def test_captions_keep_french_amounts_together(self):
        text = 'Ici, la facture indique 75 000 dirhams. Le projet n’en reprend que 15 000 : l’écart est visible.'
        lines = film.caption_lines(text)
        self.assertIn('75\u00a0000', lines)
        self.assertIn('15\u00a0000', lines)
        self.assertEqual(2, len(lines.splitlines()))
        self.assertTrue(lines.splitlines()[0].endswith('.'))

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
                       [{**scene, 'camera': [{'at': 2}, {'at': 1}]}],
                       [{**scene, 'source_start': 2, 'source_end': 1}]]:
            with self.assertRaises(ValueError):
                film.validate({'version': 1, 'id': 'demo', 'scenes': scenes})

    def test_scene_boundary_freezes_observed_state_without_revealing_future_actions(self):
        with tempfile.TemporaryDirectory(prefix='film boundary ') as folder:
            root = Path(folder)
            source, audio = root/'continuous.mp4', root/'voice.wav'
            film.run(['ffmpeg','-loglevel','error','-y','-f','lavfi','-i','color=red:s=640x480:r=10:d=0.5',
                      '-f','lavfi','-i','color=blue:s=640x480:r=10:d=0.5',
                      '-filter_complex','[0:v][1:v]concat=n=2:v=1:a=0[out]','-map','[out]',
                      '-c:v','libx264','-threads','1',source])
            film.run(['ffmpeg','-loglevel','error','-y','-f','lavfi','-i','sine=duration=1','-ar','48000',audio])
            film.export({'version':1,'id':'boundary','width':640,'height':480,'fps':10,
                         'scenes':[{'id':'review','source':str(source),'source_start':0,'source_end':0.4,
                                    'audio':str(audio),'say':'Examinez avant de confirmer.'}]},root/'out')
            pixel = subprocess.run(['ffmpeg','-loglevel','error','-ss','0.8','-i',str(root/'out/demo.mp4'),
                                    '-frames:v','1','-vf','crop=2:2:320:240','-pix_fmt','rgb24','-f','rawvideo','-'],
                                   check=True,capture_output=True).stdout
            self.assertGreater(pixel[0],pixel[2]+100)  # Still red; future blue was excluded.

    def test_real_mixed_media_export_keeps_audio_cues_and_video_frames(self):
        with tempfile.TemporaryDirectory(prefix='film smoke ') as folder:
            root = Path(folder)
            source, audio, video = root/'source.png', root/'voice.wav', root/'source.mp4'
            film.run(['ffmpeg','-loglevel','error','-y','-f','lavfi','-i','color=c=white:s=640x480','-frames:v','1','-threads','1',source])
            film.run(['ffmpeg','-loglevel','error','-y','-f','lavfi','-i','sine=frequency=440:duration=1.017','-ar','48000',audio])
            film.run(['ffmpeg','-loglevel','error','-y','-f','lavfi','-i','testsrc2=size=640x480:rate=10:duration=0.6','-c:v','libx264','-threads','1',video])
            scene = {'id':'first','source':str(source),'audio':str(audio), 'say':'Un écran clair. Une décision simple.',
                     'camera':[{'at':0,'zoom':1},{'at':1,'zoom':1.3,'x':.7}],
                     'cursor':[{'at':0,'x':.2,'y':.4},{'at':.6,'x':.7,'y':.5,'click':True}]}
            value = {'version':1,'id':'smoke','width':640,'height':480,'fps':10,
                     'run':{'verdict':'unknown'}, 'scenes':[scene,{**scene,'id':'second','shots':[{'at':0,'source':str(source)}, {'at':.5,'source':str(source)}]}, {**scene,'id':'third','source':str(video),'source_start':.1,'speed':2}]}
            result = film.export(value, root/'out')
            self.assertEqual('unknown', result['run']['verdict'])
            self.assertEqual(3, len(result['scenes']))
            info = film.probe(root/'out/demo.mp4')
            self.assertEqual(['video','audio','subtitle'], [s['codec_type'] for s in info['streams'][:3]])
            for row in result['scenes']:
                self.assertGreaterEqual(row['subtitle_end'], row['audio_end'])
            self.assertLess(abs(result['encoded_duration']-result['duration']), .1)
            self.assertEqual(3, (root/'out/subtitles.srt').read_text().count('-->'))
            self.assertTrue((root/'out/subtitles.vtt').read_text().startswith('WEBVTT'))


if __name__ == '__main__':
    unittest.main()
