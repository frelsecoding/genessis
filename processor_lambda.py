import json
import urllib.parse
import boto3
import os
import datetime

s3_client = boto3.client('s3')
dynamodb_resource = boto3.resource('dynamodb')

def lambda_handler(event, context):
    try:
        if 'Records' not in event or not event['Records'] or 's3' not in event['Records'][0]:
            raise KeyError("Missing S3 event data in Records.")
        s3_event_record = event['Records'][0]['s3']
        bucket_name = s3_event_record['bucket']['name']
        object_key = urllib.parse.unquote_plus(s3_event_record['object']['key'], encoding='utf-8')
    except Exception as e:
        print(f"Error parsing S3 event: {e}")
        return {'statusCode': 400, 'body': json.dumps({'error': f'Invalid S3 event: {e}'})}

    print(f"Processing file: s3://{bucket_name}/{object_key}")

    # --- NEW: Fetch S3 Object Metadata ---
    object_metadata_retrieved = {}
    device_id_from_metadata = None
    model_title_from_metadata = None
    original_filename_from_metadata = None

    try:
        head_response = s3_client.head_object(Bucket=bucket_name, Key=object_key)
        # Metadata keys from S3 are automatically lowercased.
        object_metadata_retrieved = head_response.get('Metadata', {}) 
        print(f"Retrieved S3 object metadata: {object_metadata_retrieved}")

        device_id_from_metadata = object_metadata_retrieved.get('device-id')
        model_title_from_metadata = object_metadata_retrieved.get('model-title')
        original_filename_from_metadata = object_metadata_retrieved.get('original-filename')

        print(f"Device ID from metadata: {device_id_from_metadata}")
        print(f"Model Title from metadata: {model_title_from_metadata}")
        print(f"Original Filename from metadata: {original_filename_from_metadata}")

    except Exception as e_meta:
        print(f"Warning: Error fetching S3 object metadata for {object_key}: {e_meta}. Proceeding without it.")
        # Metadata is optional for processing to continue, but a warning is logged.
    # --- END NEW ---

    # Use original_filename_from_metadata for a more descriptive local path if available
    base_filename_for_tmp = os.path.basename(original_filename_from_metadata) if original_filename_from_metadata else os.path.basename(object_key)
    local_audio_path = f"/tmp/{base_filename_for_tmp}"
    
    all_predictions_by_model = {ep_config['alias']: [] for ep_config in sagemaker_endpoints_to_invoke}

    try:
        # ... existing code ...
            print(f"Model '{alias}': Final: {final_genres[alias]}, Counts: {agg_counts[alias]}")

        if DYNAMODB_TABLE_NAME and dynamodb_resource:
            table = dynamodb_resource.Table(DYNAMODB_TABLE_NAME)
            
            item_to_store = {
                's3_key': object_key, 
                's3_bucket': bucket_name,
                'classified_genres_map': json.dumps(final_genres),
                'sagemaker_configs_json': SAGEMAKER_ENDPOINTS_JSON,
                'segment_preds_map': json.dumps(all_predictions_by_model),
                'process_time_utc': datetime.datetime.utcnow().isoformat(), 
                'status': 'processed'
            }
            
            # Add retrieved metadata to DynamoDB item if available
            if device_id_from_metadata:
                item_to_store['deviceID'] = device_id_from_metadata
            if model_title_from_metadata:
                item_to_store['modelTitleSelected'] = model_title_from_metadata
            if original_filename_from_metadata:
                item_to_store['originalUploadedFilename'] = original_filename_from_metadata

            table.put_item(Item=item_to_store)
            print(f"Results stored in DynamoDB: {DYNAMODB_TABLE_NAME} with item: {json.dumps(item_to_store)}")

        response_payload = {'s3_key': object_key, 'final_genres': final_genres, 'details': agg_counts}
        # ... existing code ...

    except Exception as e:
        print(f"Error processing file: {e}")
        return {'statusCode': 500, 'body': json.dumps({'error': f'Error processing file: {e}'})}

    return {'statusCode': 200, 'body': json.dumps(response_payload)}